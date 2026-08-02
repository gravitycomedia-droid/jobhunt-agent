import asyncio
import html
import logging
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

import httpx
from bs4 import BeautifulSoup

from config import settings
from models.job import JobIn
from services.apify_client import run_actor
from services.salary import infer_currency, parse_salary_text

logger = logging.getLogger(__name__)

ADZUNA_BASE = "https://api.adzuna.com/v1/api/jobs"
JSEARCH_URL = "https://jsearch.p.rapidapi.com/search-v2"
GREENHOUSE_BASE = "https://boards-api.greenhouse.io/v1/boards"
LEVER_BASE = "https://api.lever.co/v0/postings"
LINKEDIN_JOBS_SEARCH = "https://www.linkedin.com/jobs/search/"

# Unstop's public opportunity-search API — the endpoint its own frontend calls,
# no auth/cookies (confirmed by live recon 2026-07-20, docs/UNSTOP_ENDPOINT.md).
UNSTOP_SEARCH_URL = "https://unstop.com/api/public/opportunity/search-result"
# Recon tested per_page up to 100 without issue, and that's the ceiling we use:
# at 100/page the ENTIRE open catalogue is ~21 requests (836 internships + 1,186
# jobs, measured 2026-07-26), so a full crawl is cheaper in requests than the old
# per-role searchTerm loop was.
UNSTOP_PAGE_SIZE = 100

# The `opportunity` path segment. Probed live 2026-07-26: only these two carry
# actual hiring listings. "freshers" and "entry-level" are NOT opportunity types
# (both return total=0) — Unstop surfaces those as filters *inside* `jobs`, which
# is why the entry-level cut is our gate's job, not a query param.
# "competitions"/"hiring-challenges" also respond but are contests, not postings.
UNSTOP_OPPORTUNITY_TYPES = ("internships", "jobs")

# Results arrive newest-first, so once a whole page is older than
# max_job_age_days every later page is too — is_fresh() would discard them all
# anyway. Bailing there turns steady-state from a 21-request full crawl into
# ~3 requests/day. Requires TWO consecutive fully-stale pages before stopping:
# a single page of undated rows (posted_at=None) shouldn't truncate the crawl.
UNSTOP_STALE_PAGE_STREAK = 2

# Pause between pages of the same crawl. Small — the whole point is that we're a
# handful of requests a day, not a scraper — but non-zero so a cold-start full
# crawl reads as a person browsing rather than a burst of 21 parallel hits.
UNSTOP_PAGE_DELAY_SECONDS = 0.3

# Browser-like headers mirroring what unstop.com's own frontend fetch() sends —
# a real Chrome UA, a JSON Accept, same-origin Referer/Origin. Defensive against
# a WAF that reputation-scores a datacenter IP + a "JobHuntAgent/1.0" UA; the
# actual 2026-07-21 "0 jobs" bug turned out to be date parsing, not the WAF, but
# these are cheap insurance and cost nothing when the endpoint is already open.
UNSTOP_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://unstop.com/internships",
    "Origin": "https://unstop.com",
    "X-Requested-With": "XMLHttpRequest",
}

# curious_coder~linkedin-jobs-scraper rejects count < 10 with a 400
# ("Field input.count must be >= 10") — verified live 2026-07-13. So LinkedIn
# has a hard floor on how cheap a single query can be; asking for 5 doesn't
# save money, it just fails.
LINKEDIN_MIN_COUNT = 10

# Phase 1D: Adzuna reports salary_min/max in the search country's currency
# but doesn't echo the currency back — map the country code we queried
# with. Unknown country → None, and the app renders no symbol rather than
# guessing "$".
ADZUNA_COUNTRY_CURRENCY = {
    "in": "INR",
    "us": "USD",
    "gb": "GBP",
    "au": "AUD",
    "ca": "CAD",
    "de": "EUR",
    "fr": "EUR",
    "es": "EUR",
    "it": "EUR",
    "nl": "EUR",
    "at": "EUR",
    "be": "EUR",
    "ie": "EUR",
    "pl": "PLN",
    "br": "BRL",
    "sg": "SGD",
    "za": "ZAR",
    "mx": "MXN",
    "nz": "NZD",
    "ch": "CHF",
}


def _roles() -> list[str]:
    return [r.strip() for r in settings.target_roles.split(",") if r.strip()]


def _locations() -> list[str]:
    return [loc.strip() for loc in settings.target_locations.split(",") if loc.strip()]


def _adzuna_locations() -> list[str]:
    # Falls back to the shared target_locations when adzuna_locations isn't
    # set, so existing deployments keep working without a config change.
    if not settings.adzuna_locations.strip():
        return _locations()
    return [loc.strip() for loc in settings.adzuna_locations.split(",") if loc.strip()]


def _slug_name_pairs(raw: str) -> list[tuple[str, str | None]]:
    # Shared by both board APIs: entries are "slug" or "slug:Display Name".
    # A bare slug yields a None name; each caller decides what to fall back to.
    pairs: list[tuple[str, str | None]] = []
    for entry in raw.split(","):
        slug, _, name = entry.strip().partition(":")
        slug, name = slug.strip(), name.strip()
        if slug:
            pairs.append((slug, name or None))
    return pairs


def _greenhouse_boards() -> list[tuple[str, str | None]]:
    # No name → fall back to the posting's own company_name (see fetch_greenhouse).
    return _slug_name_pairs(settings.greenhouse_boards)


def _lever_companies() -> list[tuple[str, str]]:
    # Lever postings carry no company name, so the slug is the last resort.
    return [(slug, name or slug) for slug, name in _slug_name_pairs(settings.lever_companies)]


def _strip_html(raw: str | None) -> str | None:
    if not raw:
        return None
    # Greenhouse's `content` field is HTML whose own tags are themselves
    # entity-encoded (e.g. "&lt;div&gt;" as literal text, verified live
    # against the postman board) — unescape first or BeautifulSoup sees no
    # real tags and get_text() returns the entity soup unchanged.
    soup = BeautifulSoup(html.unescape(raw), "html.parser")
    return soup.get_text(separator=" ", strip=True) or None


async def fetch_adzuna() -> list[JobIn]:
    jobs: list[JobIn] = []
    async with httpx.AsyncClient(timeout=30) as client:
        for role in _roles():
            for location in _adzuna_locations():
                # Adzuna has no internship category/filter for India (verified
                # empirically against /v1/api/jobs/in/categories) — appending the
                # keyword to the free-text query is the only lever.
                #
                # The BARE role query stays, even though the pool is now
                # internships/fresher only. Dropping it (tried, 2026-07-13)
                # collapsed Adzuna to 5 postings: very few Indian listings put
                # "intern" in the TITLE, but plenty say "0-2 years" in the body —
                # and job_filter's entry-level test reads the description too. So
                # the bare query is what actually surfaces fresher roles here;
                # the relevance gate does the filtering, not the query string.
                # Adzuna is free, so three wordings cost nothing.
                for query in (role, f"{role} intern", f"{role} fresher"):
                    url = f"{ADZUNA_BASE}/{settings.adzuna_country}/search/1"
                    params = {
                        "app_id": settings.adzuna_app_id,
                        "app_key": settings.adzuna_app_key,
                        "what": query,
                        "where": location,
                        "results_per_page": 20,
                    }
                    try:
                        response = await client.get(url, params=params)
                        response.raise_for_status()
                    except httpx.HTTPError as e:
                        # One flaky query (timeout, rate limit) shouldn't sink the
                        # whole refresh cycle — skip it and keep going.
                        logger.warning("Adzuna query failed for %r/%r: %s", query, location, e)
                        continue
                    for r in response.json().get("results", []):
                        jobs.append(
                            JobIn(
                                source="adzuna",
                                external_id=str(r["id"]),
                                title=r.get("title", ""),
                                company=(r.get("company") or {}).get("display_name"),
                                location=(r.get("location") or {}).get("display_name"),
                                description=r.get("description"),
                                salary_min=r.get("salary_min"),
                                salary_max=r.get("salary_max"),
                                salary_currency=ADZUNA_COUNTRY_CURRENCY.get(settings.adzuna_country),
                                redirect_url=r.get("redirect_url"),
                                posted_at=r.get("created"),
                            )
                        )
    return jobs


async def fetch_jsearch() -> list[JobIn]:
    jobs: list[JobIn] = []
    headers = {
        "X-RapidAPI-Key": settings.rapidapi_key,
        "X-RapidAPI-Host": "jsearch.p.rapidapi.com",
    }
    async with httpx.AsyncClient(timeout=30) as client:
        for role in _roles():
            for location in _locations():
                params = {
                    # One query per role×location, NOT two — JSearch's free
                    # RapidAPI tier caps at 200 requests/MONTH (ADR-018), so an
                    # extra "fresher" wording here would blow the quota by
                    # mid-cycle. "intern" is the higher-yield of the two.
                    "query": f"{role} intern in {location}",
                    "country": settings.adzuna_country,
                    "page": 1,
                    "num_pages": 1,
                }
                try:
                    response = await client.get(JSEARCH_URL, params=params, headers=headers)
                    response.raise_for_status()
                except httpx.HTTPError as e:
                    logger.warning("JSearch query failed for %r/%r: %s", role, location, e)
                    continue
                for j in response.json().get("data", {}).get("jobs", []):
                    jobs.append(
                        JobIn(
                            source="jsearch",
                            external_id=j["job_id"],
                            title=j.get("job_title", ""),
                            company=j.get("employer_name"),
                            location=j.get("job_location"),
                            description=j.get("job_description"),
                            salary_min=j.get("job_min_salary"),
                            salary_max=j.get("job_max_salary"),
                            salary_currency=j.get("job_salary_currency"),
                            redirect_url=j.get("job_apply_link"),
                            posted_at=j.get("job_posted_at_datetime_utc"),
                        )
                    )
    return jobs


# ---------------------------------------------------------------------------
# Apify-scraped sources (ADR-003, amended 2026-07-13)
#
# Every field name below was read off a live run against each actor on
# 2026-07-13, not inferred from its store page — the three actors share no
# common output shape (Indeed says `positionName`, LinkedIn says `title`,
# Naukri says `title` but hides the real description behind `fetchDetails`),
# and a wrong guess against a pay-per-result API bills you for rows that land
# with an empty title.
#
# All three follow fetch_adzuna()'s error contract: run_actor() never raises, so
# a dead actor yields [] and the other sources still ingest.
# ---------------------------------------------------------------------------


# Metro-area noise the boards wrap city names in. Stripped before the canonical
# lookup below, so "Greater Bengaluru Area" and "Bengaluru East" both reduce to
# "bengaluru" and then to "Bangalore".
_CITY_NOISE = (
    "greater",
    "metropolitan region",
    "metropolitan area",
    "urban",
    "division",
    "district",
    "area",
    "east",
    "west",
    "north",
    "south",
)

# One spelling per city. The pair that actually bites is Bangalore/Bengaluru:
# Adzuna says one, LinkedIn says the other, and without this they are two
# different dedup keys for one place — the same job lands twice.
_CANONICAL_CITIES = {
    "bengaluru": "Bangalore",
    "bangalore": "Bangalore",
    "bangalore city": "Bangalore",
    "hyderabad": "Hyderabad",
    "secunderabad": "Hyderabad",
    "mumbai": "Mumbai",
    "navi mumbai": "Mumbai",
    "bombay": "Mumbai",
    "pune": "Pune",
    "chennai": "Chennai",
    "delhi": "Delhi NCR",
    "new delhi": "Delhi NCR",
    "noida": "Delhi NCR",
    "gurgaon": "Delhi NCR",
    "gurugram": "Delhi NCR",
    "ncr": "Delhi NCR",
    "kolkata": "Kolkata",
    "ahmedabad": "Ahmedabad",
    "remote": "Remote",
}


def _primary_city(raw: str | None) -> str | None:
    """Collapse a source's location string to one canonical city.

    Each board spells the same place differently — Indeed "Hyderabad,
    Telangana", LinkedIn "Greater Hyderabad Area" / "Bengaluru East", Naukri
    "Hybrid - Hyderabad, Chennai, Delhi / NCR" (all observed live). dedup_key is
    slugify(title|company|location), so left alone one posting cross-listed on
    two boards yields two keys and lands twice. Canonicalizing here is what lets
    the existing exact-match dedup fire ACROSS sources at all.

    An unrecognized place is passed through cleaned-but-unmapped rather than
    dropped: a job in Kozhikode is still a real job, it just won't cross-dedup.
    """
    if not raw:
        return None
    text = raw.strip()

    # "Hybrid - Hyderabad" / "Remote - Pune": a Naukri work-mode prefix, not
    # part of the place name.
    lowered = text.lower()
    for prefix in ("hybrid -", "remote -", "work from office -", "on-site -"):
        if lowered.startswith(prefix):
            text = text[len(prefix) :].strip()
            break

    head = text.split(",")[0].strip()
    if not head:
        return None

    # Strip metro-area decoration: "Greater Bengaluru Area" → "bengaluru".
    cleaned = head.lower()
    for noise in _CITY_NOISE:
        cleaned = re.sub(rf"(?<![a-z]){re.escape(noise)}(?![a-z])", " ", cleaned)
    cleaned = " ".join(cleaned.split())

    return _CANONICAL_CITIES.get(cleaned, head)


def _linkedin_search_url(role: str, location: str) -> str:
    """This actor takes LinkedIn search URLs, not role/location fields — so we
    build the URL LinkedIn's own job search would produce.

    The internship bias rides on the KEYWORDS, not on LinkedIn's `f_E`
    experience-level param. f_E was the obvious answer and it does not work:
    tested live, this actor ignores it entirely (f_E=1, "internships only",
    still returned a Mid-Senior "Senior Full-Stack Software Engineer"). Putting
    it in the URL would have been code that reads correctly and does nothing.

    Keeping it to one query per role is deliberate — a separate "<role> intern"
    call, which is what fetch_adzuna() does, would double the Apify call count
    and the bill.
    """
    keywords = f"{role} {settings.apify_linkedin_query_suffix}".strip()
    return f"{LINKEDIN_JOBS_SEARCH}?{urlencode({'keywords': keywords, 'location': location})}"


async def fetch_linkedin_apify(role: str, location: str, max_results: int) -> list[JobIn]:
    """LinkedIn via curious_coder~linkedin-jobs-scraper (no-login, $0.001/result).

    Salary arrives as free text (often "") — parsed in Python, per golden rule 2.
    """
    count = max(max_results, LINKEDIN_MIN_COUNT)  # actor 400s below 10
    rows = await run_actor(
        settings.apify_linkedin_actor_id,
        {
            "urls": [_linkedin_search_url(role, location)],
            "count": count,
            "scrapeCompany": False,  # company detail costs extra and we don't use it
        },
    )

    jobs: list[JobIn] = []
    for r in rows:
        external_id = r.get("id")
        title = r.get("title")
        if not external_id or not title:
            # No stable ID or no title → nothing worth deduping or ranking.
            continue
        raw_location = r.get("location")
        salary_min, salary_max, currency = parse_salary_text(r.get("salary"))
        jobs.append(
            JobIn(
                source="linkedin",
                external_id=str(external_id),
                title=title,
                company=r.get("companyName"),
                location=_primary_city(raw_location),
                description=r.get("descriptionText"),
                salary_min=salary_min,
                salary_max=salary_max,
                # No source-level default: LinkedIn is global, so an
                # unrecognized city means "unknown currency", not USD.
                salary_currency=currency or infer_currency(raw_location),
                redirect_url=r.get("link"),
                posted_at=r.get("postedAt"),
            )
        )
    return jobs


async def fetch_indeed_apify(role: str, location: str, max_results: int) -> list[JobIn]:
    """Indeed via misceres~indeed-scraper (no-login, $0.006/result — the priciest
    of the three, which is why it's disabled by default; see .env.example)."""
    # This actor has no experience-level input (unlike LinkedIn's f_E and
    # Naukri's experienceMax), so the only lever is the query text itself.
    # Appending "intern" biases the same single call toward internships/fresher
    # roles rather than spending a second call on a separate intern query, which
    # would double Indeed's spend — and Indeed is the priciest per job of the
    # sources we run.
    position = f"{role} {settings.apify_indeed_query_suffix}".strip()
    rows = await run_actor(
        settings.apify_indeed_actor_id,
        {
            "position": position,
            "location": location,
            "country": settings.adzuna_country.upper(),  # reuse the existing country config ("in" → "IN")
            "maxItemsPerSearch": max_results,
            "parseCompanyDetails": False,
            "saveOnlyUniqueItems": True,
        },
    )

    jobs: list[JobIn] = []
    for r in rows:
        external_id = r.get("id")
        title = r.get("positionName")
        if not external_id or not title:
            continue
        if r.get("isExpired"):
            # Indeed keeps serving expired postings; ingesting one means the
            # user clicks through to a dead page. Cheaper to drop it here.
            continue
        raw_location = r.get("location")
        salary_min, salary_max, currency = parse_salary_text(r.get("salary"))
        jobs.append(
            JobIn(
                source="indeed",
                external_id=str(external_id),
                title=title,
                company=r.get("company"),
                location=_primary_city(raw_location),
                description=r.get("description"),
                salary_min=salary_min,
                salary_max=salary_max,
                salary_currency=currency or infer_currency(raw_location),
                redirect_url=r.get("url"),
                # `postedAt` is relative ("2 days ago"); postingDateParsed is the
                # ISO timestamp the freshness gate can actually compare.
                posted_at=r.get("postingDateParsed"),
            )
        )
    return jobs


async def fetch_naukri_apify(role: str, location: str, max_results: int) -> list[JobIn]:
    """Naukri via makework36~naukri-scraper (no-login).

    Two things this actor gets right that the others don't: it splits INR salary
    strings into numeric salaryMin/salaryMax/salaryCurrency for us, and (with
    fetchDetails) it returns a full jobDescription. Without fetchDetails the only
    description is `jobDescriptionPreview` — a ~90-char truncated stub, which
    would quietly hand Naukri jobs weaker embeddings and worse rerank scores than
    every other source for reasons having nothing to do with the job.

    Caveat: this actor is young (≈80% success rate). A failed run yields [] and
    the day simply has no Naukri jobs — verified live, it happens.
    """
    rows = await run_actor(
        settings.apify_naukri_actor_id,
        {
            "mode": "keywords",
            "keywords": [role],
            "cities": [location.lower()],
            "maxJobs": max_results,
            "fetchDetails": settings.apify_naukri_fetch_details,
            # Naukri filters by years of experience natively, so capping it here
            # surfaces internships and fresher roles on the SAME call — no second
            # "<role> intern" query, and Naukri is the priciest source per job.
            # 0..2 years keeps genuine fresher full-time roles in, not just interns.
            "experienceMin": 0,
            "experienceMax": settings.apify_naukri_max_experience_years,
        },
        # fetchDetails opens each JD page in turn, so this actor is far slower
        # than the other two — it blew the default 120s timeout on a live run
        # and lost the whole source's jobs. 280s sits just under Apify's 300s
        # hard cap on run-sync.
        timeout_s=280 if settings.apify_naukri_fetch_details else 120,
    )

    jobs: list[JobIn] = []
    for r in rows:
        external_id = r.get("jobId")
        title = r.get("title")
        if not external_id or not title:
            continue
        # `locations` is the parsed array; locationText is the display string
        # ("Hybrid - Hyderabad, Chennai"). Prefer the array's first entry.
        locations = r.get("locations") or []
        raw_location = locations[0] if locations else r.get("locationText")

        salary_min, salary_max = r.get("salaryMin"), r.get("salaryMax")
        currency = r.get("salaryCurrency")
        if salary_min is None and salary_max is None:
            # Actor didn't split it — fall back to parsing salaryText ourselves
            # ("6-15 Lacs PA").
            salary_min, salary_max, parsed_currency = parse_salary_text(r.get("salaryText"))
            currency = currency or parsed_currency

        jobs.append(
            JobIn(
                source="naukri",
                external_id=str(external_id),
                title=title,
                company=r.get("companyName"),
                location=_primary_city(raw_location),
                # Full description when fetchDetails is on; the stub otherwise.
                description=r.get("jobDescription") or r.get("jobDescriptionPreview"),
                salary_min=salary_min,
                salary_max=salary_max,
                # Naukri is India-only, so INR is a defensible source-level
                # default here in a way it would NOT be for LinkedIn/Indeed.
                salary_currency=currency or infer_currency(raw_location, default="INR"),
                redirect_url=r.get("jobUrl"),
                posted_at=r.get("postedDate"),
            )
        )
    return jobs


def _internshala_posted_at(badge: str | None, now: datetime | None = None) -> datetime | None:
    """Internshala's relative-time badge → an absolute UTC timestamp.

    The listing HTML carries no absolute date anywhere — only a rendered badge
    ("Just now", "Today", "2 days ago", "3 weeks ago"). is_fresh() needs a real
    datetime, so the badge is resolved against `now` at parse time.

    Deliberately coarse: "3 weeks ago" becomes exactly 21 days back, not a range.
    The only consumer is the ≤max_job_age_days freshness cut, where day-level
    precision is all that can matter. An unrecognized badge returns None rather
    than guessing "now" — an undated posting must not be able to masquerade as
    fresh, and is_fresh() already has a defined answer for None.
    """
    if not badge:
        return None
    text = badge.strip().lower()
    now = now or datetime.now(timezone.utc)

    if text in ("just now", "today"):
        return now
    if text == "yesterday":
        return now - timedelta(days=1)

    m = re.match(r"^(\d+)\s+(hour|day|week|month)s?\s+ago$", text)
    if not m:
        return None
    amount, unit = int(m.group(1)), m.group(2)
    delta = {
        "hour": timedelta(hours=amount),
        "day": timedelta(days=amount),
        "week": timedelta(weeks=amount),
        "month": timedelta(days=30 * amount),
    }[unit]
    return now - delta


# The badge text itself, matched anchored so a stray "Today" inside a company
# name or a skill tag can't be mistaken for a posting date.
_INTERNSHALA_BADGE = re.compile(r"^(just now|today|yesterday|\d+\s+(hour|day|week|month)s?\s+ago)$", re.I)

# Internshala's technical category slugs, confirmed against the site's own
# category nav on 2026-07-27. Internships and fresher-jobs use different URL
# stems for the same slug, so the stem is applied at fetch time.
#
# Restricting to these ~12 is the FIRST of two IT filters — it removes the
# marketing/finance/HR categories wholesale. It is not sufficient on its own:
# a "Food Technologist" and a "Quality Inspector" were both observed on the
# computer-science page, which is why every card still goes through the
# category classifier downstream.
INTERNSHALA_TECH_SLUGS = (
    "computer-science",
    "web-development",
    "mobile-app-development",
    "programming",
    "software-development",
    "software-testing",
    "cloud-computing",
    "cyber-security",
    "network-engineering",
    "blockchain-development",
    "data-science",
    "machine-learning",
)

INTERNSHALA_BASE = "https://internshala.com"

# Same posture as UNSTOP_PAGE_DELAY_SECONDS: we are a handful of requests a day,
# not a scraper, but the delay is non-zero so a multi-category pass reads as a
# person browsing rather than a burst of parallel hits. ADR-003 v4 constraint.
INTERNSHALA_PAGE_DELAY_SECONDS = 0.5

INTERNSHALA_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}


def _internshala_card_to_job(card, now: datetime | None = None, entry_level_hint: bool | None = None) -> JobIn | None:
    """One `.individual_internship` card → JobIn. Never raises; a card missing
    an id or a title is skipped rather than half-mapped.

    Selectors pinned against live markup on 2026-07-27 (a saved trim of that
    response is server/tests/fixtures/internshala_listing.html, so a markup
    change shows up as a test failure rather than a silent zero-row day).
    """
    external_id = card.get("internshipid")
    title_el = card.select_one(".job-internship-name")
    if not external_id or not title_el:
        return None
    title = title_el.get_text(" ", strip=True)
    if not title:
        return None

    badge = None
    for span in card.select(".color-labels span"):
        text = span.get_text(strip=True)
        if _INTERNSHALA_BADGE.match(text):
            badge = text
            break

    company_el = card.select_one(".company-name")
    location_el = card.select_one(".locations")
    stipend_el = card.select_one(".stipend")
    about_el = card.select_one(".about_job")

    # Skill tags are prepended to the JD text rather than dropped: they are the
    # cleanest signal both the embedding and the category classifier get from
    # this source, and the `.about_job` blurb is often generic prose.
    skills = [s.get_text(strip=True) for s in card.select(".job_skill")]
    description = about_el.get_text(" ", strip=True) if about_el else None
    if skills:
        description = f"Skills: {', '.join(skills)}. {description or ''}".strip()

    raw_location = location_el.get_text(" ", strip=True) if location_el else None
    salary_min, salary_max, currency = parse_salary_text(stipend_el.get_text(" ", strip=True) if stipend_el else None)

    link = card.select_one("a.job-title-href")
    href = link.get("href") if link else None
    redirect_url = f"{INTERNSHALA_BASE}{href}" if href and href.startswith("/") else href

    return JobIn(
        source="internshala",
        external_id=str(external_id),
        title=title,
        company=company_el.get_text(" ", strip=True) if company_el else None,
        location=_primary_city(raw_location),
        description=description or None,
        salary_min=salary_min,
        salary_max=salary_max,
        # India-only source, so a missing currency defaults to INR, not $.
        salary_currency=currency or infer_currency(raw_location, default="INR"),
        redirect_url=redirect_url,
        posted_at=_internshala_posted_at(badge, now),
        entry_level_hint=entry_level_hint,
    )


def parse_internshala_html(
    markup: str, now: datetime | None = None, entry_level_hint: bool | None = None
) -> list[JobIn]:
    """All parseable cards in one listing page. Pure (no I/O) so the selectors
    are unit-testable against the saved fixture.

    `entry_level_hint` is passed down from the CALLER, which knows which URL
    stem it fetched — the markup itself carries no reliable seniority signal
    (card titles are profile names like "Android App Development", so only 3 of
    50 contain "intern").
    """
    soup = BeautifulSoup(markup, "html.parser")
    jobs: list[JobIn] = []
    for card in soup.select(".individual_internship"):
        try:
            job = _internshala_card_to_job(card, now, entry_level_hint)
        except Exception as e:
            # One malformed card must not lose the other 49 on the page.
            logger.warning("Internshala card parse failed: %s: %s", type(e).__name__, e)
            continue
        if job:
            jobs.append(job)
    return jobs


async def fetch_internshala() -> list[JobIn]:
    """Internshala via plain HTTP + BeautifulSoup — free, no Apify, no JS.

    Replaces fetch_internshala_apify() (ADR-003 v4, 2026-07-27). Recon on
    2026-07-27 confirmed the category listing pages are server-rendered: a bare
    GET returns all 50 cards per page with title, company, location, stipend,
    duration, skill tags and a relative posted-time badge already in the HTML.
    Nothing the paid actor provided required the actor. Going free is what lets
    this run DAILY at full page depth instead of tue/fri capped at 10 results.

    Two constraints worth not "simplifying" away later:

    1. **No early-stop on the first stale card.** Cards are NOT uniformly
       recency-sorted — measured on the live computer-science page, positions
       1-32 are a promoted/featured block in mixed order ("3 weeks ago" sat at
       position 1, "Just now" at position 2) and only the tail is sorted. An
       early-stop on the first non-fresh badge would have returned zero jobs.
       Every card on a fetched page is parsed.
    2. **Freshness is is_fresh()'s job, not this function's.** The badge is
       resolved into a real posted_at and the shared ≤max_job_age_days gate in
       _dedup_embed_insert() does the cutting, exactly like every other source.
       Filtering to "Just now"/"Today" here would make this the one source with
       a private, stricter freshness rule.

    Per-category and per-page errors are swallowed (logged, then continue) so
    one 404 slug or one throttled page never sinks the day's whole fetch —
    the same tolerance pattern as fetch_adzuna()/fetch_jsearch().
    """
    slugs = [s.strip() for s in settings.internshala_slugs.split(",") if s.strip()]
    pages = max(1, settings.internshala_pages_per_slug)
    # (name, url template, entry_level_hint). The hint is True only for the
    # internships stem: everything on those pages IS an internship because of the
    # URL we requested, which is stronger evidence than any title-text guess.
    #
    # fresher-jobs gets None, NOT True. Despite the name, that catalogue is
    # full-time roles pitched at freshers and does carry the occasional
    # experienced posting, so it keeps going through the normal text check.
    stems = [("internships", "{base}/internships/{slug}-internship/", True)]
    if settings.internshala_include_fresher_jobs:
        # The fresher-jobs catalogue is full-time entry roles rather than
        # internships — same markup, different stem. Free, so unlike the Apify
        # path there is no "don't double the bill" reason to skip it.
        stems.append(("fresher-jobs", "{base}/fresher-jobs/{slug}-jobs/", None))

    jobs: list[JobIn] = []
    now = datetime.now(timezone.utc)
    async with httpx.AsyncClient(timeout=30, headers=INTERNSHALA_HEADERS, follow_redirects=True) as client:
        for _, template, entry_hint in stems:
            for slug in slugs:
                base_url = template.format(base=INTERNSHALA_BASE, slug=slug)
                for page in range(1, pages + 1):
                    url = base_url if page == 1 else f"{base_url.rstrip('/')}/page-{page}/"
                    try:
                        response = await client.get(url)
                        response.raise_for_status()
                    except Exception as e:
                        # A slug that doesn't exist for this stem 404s — expected
                        # for some combinations, so this is a warning, not an error.
                        logger.warning("Internshala %s failed: %s: %s", url, type(e).__name__, e)
                        break
                    page_jobs = parse_internshala_html(response.text, now, entry_hint)
                    jobs.extend(page_jobs)
                    if not page_jobs:
                        # Past the last page of this category — no point walking
                        # deeper into empty pages.
                        break
                    await asyncio.sleep(INTERNSHALA_PAGE_DELAY_SECONDS)

    logger.info("Internshala: parsed %d cards across %d slugs × %d stems", len(jobs), len(slugs), len(stems))
    return jobs


# Instahyre's public job-search API — the endpoint its own /search-jobs/ page
# calls. Confirmed live 2026-07-27 with NO auth, cookies or session of any kind.
INSTAHYRE_SEARCH_URL = "https://www.instahyre.com/api/v1/job_search"

# `job_categories=1` is Instahyre's own "Software Engineering" bucket (confirmed
# by reading the request its Software Engineering Jobs page issues). This is the
# source-side IT filter and does most of the work before our code sees a row —
# but it is NOT trusted alone: every row still goes through the shared category
# classifier downstream, same as Internshala.
INSTAHYRE_SOFTWARE_CATEGORY = 1

# 2 = internship, 0 = full-time. INTERNSHIPS FIRST, and the order is load-bearing.
#
# Measured live 2026-07-27: full-time is 7,911 rows and skews overwhelmingly
# senior (an entire sample page was Staff/Principal/Senior — 120/120 rejected by
# the entry-level gate), while the internship catalogue is ~8 rows of which most
# survive. Since both crawls share one cap, iterating full-time first let it
# consume the entire budget before internships were ever requested — so the only
# part of this source that can actually pass the gate was never fetched, and
# Instahyre inserted exactly 0 rows on its first production run.
#
# Cheapest correct fix: ask for the small, high-yield catalogue first. The cap
# then bounds the low-yield one, which is what it was always for.
INSTAHYRE_JOB_TYPES = (2, 0)

INSTAHYRE_PAGE_SIZE = 50
INSTAHYRE_PAGE_DELAY_SECONDS = 0.3

# Hard ceiling on pages per job_type, independent of the row cap.
#
# The row cap alone is NOT a termination guarantee: new rows are deduped by id
# before being counted, so a source that keeps handing back `meta.next` with
# content we've already seen never grows `len(jobs)` and the crawl spins
# forever. Found by a test that modelled exactly that (a paginating endpoint
# returning repeated ids) and hung the suite.
#
# At 50 rows/page this bounds a crawl at 2,000 rows — far above any cap we'd
# realistically set, so it never binds in normal operation. It exists purely so
# a misbehaving or malicious endpoint costs a bounded number of requests instead
# of hanging the daily pipeline.
INSTAHYRE_MAX_PAGES = 40

INSTAHYRE_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.instahyre.com/search-jobs/",
}


def _instahyre_row_to_job(r: dict) -> JobIn | None:
    """One `objects[]` entry → JobIn. Returns None for a row missing an id or a
    title rather than inventing either."""
    external_id = r.get("id")
    # candidate_title already carries the "(Internship)" suffix where relevant,
    # which the entry-level gate reads — so prefer it over the plain `title`.
    title = r.get("candidate_title") or r.get("title")
    if not external_id or not title:
        return None

    employer = r.get("employer") or {}
    # `locations` is a COMMA-SEPARATED STRING ("Bangalore,Noida,Pune"), not an
    # array — _primary_city already collapses on the first comma, so it needs no
    # special handling here, but the shape is easy to misread.
    raw_location = r.get("locations")

    # keywords[] are clean skill tags ("Python", "Django", "React.js"). This
    # source has no JD text at all in the search response, so the tags plus the
    # employer blurb ARE the description — they're what gets embedded and what
    # the category classifier reads.
    keywords = [k for k in (r.get("keywords") or []) if k]
    parts = []
    if keywords:
        parts.append(f"Skills: {', '.join(keywords)}.")
    if employer.get("instahyre_note"):
        parts.append(employer["instahyre_note"])
    elif employer.get("company_tagline"):
        parts.append(employer["company_tagline"])

    return JobIn(
        source="instahyre",
        external_id=str(external_id),
        title=title,
        company=employer.get("company_name"),
        location=_primary_city(raw_location),
        description=" ".join(parts) or None,
        # No salary anywhere in the search response — left null rather than guessed.
        salary_min=None,
        salary_max=None,
        salary_currency=None,
        redirect_url=r.get("public_url"),
        # DELIBERATELY None: the response carries no posting date. `reviewed_at`
        # looks like one but is a candidate-interaction field (always null on a
        # public query). is_fresh() passes undated rows, so "new today" for this
        # source is decided by dedup — an id we haven't stored is new. That is
        # the ceiling the API allows, not an oversight.
        posted_at=None,
    )


async def fetch_instahyre(max_results: int | None = None) -> list[JobIn]:
    """Instahyre via its public JSON API — free, no auth, no Apify (ADR-003 v4).

    Crawls the Software Engineering category for both full-time and internship
    listings, paginating via the response's own `meta.next` until it runs out or
    the cap is hit. Per-page errors are swallowed so one bad page doesn't sink
    the rest, matching the Adzuna/JSearch tolerance pattern.
    """
    cap = max_results if max_results is not None else settings.instahyre_max_results
    jobs: list[JobIn] = []
    seen_ids: set[str] = set()

    async with httpx.AsyncClient(timeout=30, headers=INSTAHYRE_HEADERS, follow_redirects=True) as client:
        for job_type in INSTAHYRE_JOB_TYPES:
            params = {
                "company_size": 0,
                "isLandingPage": "true",
                "job_type": job_type,
                "job_categories": INSTAHYRE_SOFTWARE_CATEGORY,
                "offset": 0,
                "limit": INSTAHYRE_PAGE_SIZE,
                "source": "opportunities",
            }
            url = f"{INSTAHYRE_SEARCH_URL}?{urlencode(params)}"

            pages = 0
            while url and len(jobs) < cap and pages < INSTAHYRE_MAX_PAGES:
                pages += 1
                try:
                    response = await client.get(url)
                    response.raise_for_status()
                    payload = response.json()
                except Exception as e:
                    logger.warning("Instahyre job_type=%s page failed: %s: %s", job_type, type(e).__name__, e)
                    break

                rows = payload.get("objects") or []
                for r in rows:
                    job = _instahyre_row_to_job(r)
                    # The two job_type crawls can surface the same posting; drop
                    # the repeat here so `fetched` counts don't double-count it.
                    if job and job.external_id not in seen_ids:
                        seen_ids.add(job.external_id)
                        jobs.append(job)

                # meta.next is a ready-to-use relative URL, or null on the last
                # page. Following it beats recomputing offsets ourselves.
                next_path = (payload.get("meta") or {}).get("next")
                if not next_path or not rows:
                    break
                url = f"https://www.instahyre.com{next_path}"
                await asyncio.sleep(INSTAHYRE_PAGE_DELAY_SECONDS)

    logger.info("Instahyre: fetched %d listings (cap %d)", len(jobs), cap)
    return jobs[:cap]


# Unstop hands us a period word rather than a suffix on a string. Monthly stipends
# must be annualized (×12) so an internship's "₹15,000/month" sits on the same
# axis as an Adzuna per-year salary — the same normalization salary.py does for
# text. Only 'monthly' is multiplied: an unknown/lump-sum period is left as-is
# rather than guessed, matching salary.py's refusal to invent a period.
_UNSTOP_PERIOD_MULTIPLIER = {"monthly": 12, "yearly": 1, "annually": 1, "annual": 1}


def _unstop_posted_at(raw) -> datetime | None:
    """Unstop's approved_date is "2026-07-08 01:21:36 GMT+0530" — the literal
    "GMT" before the offset makes it unparseable by pydantic and by strptime's
    %z alike, so every Unstop row failed JobIn validation and got dropped (the
    2026-07-21 "0 jobs" incident). Strip the "GMT" and parse; fall back to the
    date alone, then to None. Never raises."""
    if not isinstance(raw, str) or not raw.strip():
        return None
    cleaned = raw.replace("GMT", "").strip()
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(cleaned, fmt)
        except ValueError:
            continue
    try:
        return datetime.strptime(cleaned[:10], "%Y-%m-%d")
    except ValueError:
        return None


def _unstop_row_to_job(r: dict) -> JobIn | None:
    """Map one Unstop opportunity object into JobIn, or None if it lacks a stable
    id/title. Field paths are from the Phase B recon (docs/UNSTOP_ENDPOINT.md),
    captured off a live call — not guessed like the Internshala actor's."""
    external_id = r.get("id")
    title = r.get("title")
    if not external_id or not title:
        return None

    # locations[] can be empty for remote-only postings; take the first city.
    city = next((loc.get("city") for loc in (r.get("locations") or []) if isinstance(loc, dict) and loc.get("city")), None)

    detail = r.get("jobDetail") or {}
    # A work-from-home posting has no city but IS eligible (remote is location-
    # independent). Tag it "Remote" from Unstop's structured work-mode so the
    # relevance gate's remote path catches it reliably — better than hoping the
    # JD text says "work from home".
    if not city and (detail.get("type") == "wfh" or r.get("isWorkFromHome") is True):
        city = "Remote"
    # min_salary/max_salary are clean ints ALREADY — no salary.py text parse here
    # (that's Naukri's "6-15 Lacs PA" job). They're null when the posting is unpaid.
    paid = detail.get("paid_unpaid") == "paid"
    salary_min = detail.get("min_salary") if paid else None
    salary_max = detail.get("max_salary") if paid else None

    # Unstop opportunities here are all internships, whose stipends are
    # effectively always monthly — so a MISSING pay_in defaults to monthly (x12),
    # not x1, which would render a ₹12,000/month stipend as a ₹12,000/YEAR salary.
    # A present-but-unrecognized period (a one-time/lump-sum prize) is left as-is.
    period = (detail.get("pay_in") or "").strip().lower()
    mult = 12 if not period else _UNSTOP_PERIOD_MULTIPLIER.get(period, 1)
    if salary_min is not None:
        salary_min *= mult
    if salary_max is not None:
        salary_max *= mult

    # currency is a Font Awesome icon class ("fa-rupee"), NOT free text — map it
    # directly. Unstop is India-only, so an unmapped/missing value still defaults
    # to INR (never "$" by omission), same posture as Naukri/Internshala.
    raw_currency = detail.get("currency")
    currency = "INR" if raw_currency == "fa-rupee" else infer_currency(city, default="INR")

    return JobIn(
        source="unstop",
        external_id=str(external_id),
        title=title,
        company=(r.get("organisation") or {}).get("name"),
        location=_primary_city(city),
        description=_strip_html(r.get("details")),  # `details` is HTML, like Greenhouse's content
        salary_min=salary_min,
        salary_max=salary_max,
        salary_currency=currency,
        redirect_url=r.get("seo_url"),
        posted_at=_unstop_posted_at(r.get("approved_date")),
        # The registration deadline Unstop publishes on every opportunity. This
        # is what makes expiry a FACT rather than an age guess: registration
        # windows here run 13 days at the median and up to 56, so a 12-day-old
        # posting is routinely still open and a 40-day-old one sometimes is.
        # Plain ISO-8601 with an offset, unlike approved_date's "GMT+0530"
        # mess, so pydantic parses it without help.
        expires_at=r.get("end_date"),
    )


def _unstop_opportunity_types() -> list[str]:
    """Which Unstop catalogues to crawl. Unknown values are dropped with a loud
    log rather than sent: a typo'd type returns total=0, which would look exactly
    like "the source died" in the Phase F health log."""
    raw = [t.strip().lower() for t in settings.unstop_opportunity_types.split(",") if t.strip()]
    valid = [t for t in raw if t in UNSTOP_OPPORTUNITY_TYPES]
    if len(valid) != len(raw):
        logger.warning(
            "Unstop: ignoring unknown opportunity type(s) %s — valid values are %s",
            sorted(set(raw) - set(valid)),
            list(UNSTOP_OPPORTUNITY_TYPES),
        )
    return valid


def _unstop_search_terms() -> list[str | None]:
    """Empty setting → [None], i.e. ONE unfiltered pass over the whole catalogue.

    This inverts the pre-2026-07-26 behaviour, which searched once per
    `target_roles` entry. That kept the fetch narrow but capped the pool at the
    three fullstack/frontend/cloud role names; the broad pool (ADR-003 v3) wants
    every category, and a full crawl is also FEWER requests than three keyword
    passes. Set UNSTOP_SEARCH_TERMS to go back to keyword mode.
    """
    terms = [t.strip() for t in settings.unstop_search_terms.split(",") if t.strip()]
    return list(terms) if terms else [None]


def _unstop_page_is_stale(jobs: list[JobIn], now: datetime) -> bool:
    """True when every DATED job on the page is older than max_job_age_days.

    Undated rows (posted_at=None) don't count as stale — they're unknown, not
    old — so a page of them can't trigger the early stop on its own. A page with
    no dated rows at all returns False for the same reason.
    """
    dated = [j for j in jobs if j.posted_at]
    if not dated:
        return False
    cutoff = timedelta(days=settings.max_job_age_days)
    return all(now - j.posted_at.astimezone(timezone.utc) > cutoff for j in dated)


async def fetch_unstop(max_results: int, stop_when_stale: bool = True) -> list[JobIn]:
    """Unstop internships AND jobs via its public search API (ADR-003 v2/v3, no login).

    Direct httpx, not Apify: the endpoint carries no per-result cost, so unlike
    the Apify sources there's no cost-cadence to schedule around — it's capped by
    UNSTOP_MAX_RESULTS purely to stay a light, non-aggressive caller (ADR-003's
    "no high-volume polling"). Follows fetch_adzuna()'s error contract: a failed
    page logs and stops the loop, never raises, so a bad response yields whatever
    was already collected rather than sinking the pipeline.

    `max_results` is a cap PER (opportunity type × search term), not a grand
    total — same shape as the Apify sources' per-call cap, so adding a second
    opportunity type doesn't silently halve the internship budget.

    Volume note (measured live 2026-07-26): the full open catalogue is ~836
    internships + ~1,186 jobs = ~21 requests at 100/page. Steady state is far
    cheaper than that because results are newest-first and the crawl stops after
    UNSTOP_STALE_PAGE_STREAK consecutive pages that are entirely older than
    max_job_age_days — typically ~3 requests/day.
    """
    if max_results <= 0:
        return []
    per_page = min(max_results, UNSTOP_PAGE_SIZE)
    now = datetime.now(timezone.utc)

    jobs: list[JobIn] = []
    # follow_redirects: a WAF may 302 a suspicious request to a challenge/login
    # page; following it lets response.json() fail cleanly (→ skip) instead of us
    # misreading a 302 body. The URL is a fixed constant, not user input, so
    # there's no SSRF concern in following redirects here.
    async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
        for opportunity in _unstop_opportunity_types():
            for term in _unstop_search_terms():
                found = await _crawl_unstop(
                    client, opportunity, term, max_results, per_page, now, stop_when_stale
                )
                logger.info("Unstop %s/%r: %d rows", opportunity, term, len(found))
                jobs += found

    return jobs


async def _crawl_unstop(
    client: httpx.AsyncClient,
    opportunity: str,
    term: str | None,
    max_results: int,
    per_page: int,
    now: datetime,
    stop_when_stale: bool = True,
) -> list[JobIn]:
    """One paginated crawl of a single (opportunity type, search term) pair.

    Split out of fetch_unstop() so the two nested loops don't bury the pagination
    logic three indents deep. Never raises — every exit path is a `break` that
    returns whatever was collected, matching fetch_adzuna()'s error contract.

    `stop_when_stale=False` walks the WHOLE catalogue instead of stopping once
    pages go older than max_job_age_days. Daily ingestion wants the early stop
    (~3 requests instead of ~21, and those rows would fail is_fresh() anyway).
    The expiry backfill needs the opposite: it decides which held postings have
    left the catalogue, and absence only means "closed" if the crawl was
    complete. A partial view would read as "everything vanished".
    """
    jobs: list[JobIn] = []
    page = 1
    stale_pages = 0
    while len(jobs) < max_results:
        params = {
            "opportunity": opportunity,
            "page": page,
            "per_page": per_page,
            "oppstatus": "open",  # currently-open postings only
        }
        if term:
            params["searchTerm"] = term
        try:
            response = await client.get(UNSTOP_SEARCH_URL, params=params, headers=UNSTOP_HEADERS)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as e:
            logger.warning("Unstop %s/%r page %d request failed: %s", opportunity, term, page, e)
            break

        # Scraped frontend API we don't control: from some networks (a
        # datacenter IP, a WAF challenge) it can 200 with a different shape
        # than the recon captured, so every level is type-checked rather
        # than trusted. A wrong shape logs WHAT it got and stops — never
        # raises, so the pipeline and the Phase F health row survive.
        paginator = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(paginator, dict):
            logger.warning(
                "Unstop %s/%r page %d: unexpected response shape (data=%s) — possible WAF/IP block",
                opportunity,
                term,
                page,
                type(paginator).__name__,
            )
            break

        rows = paginator.get("data")
        if not isinstance(rows, list) or not rows:
            break

        page_jobs: list[JobIn] = []
        for r in rows:
            if not isinstance(r, dict):
                continue
            try:
                job = _unstop_row_to_job(r)
            except Exception as e:
                # One malformed row must not lose the page — skip and log.
                logger.warning("Unstop row skipped (mapping error): %s", e)
                continue
            if job:
                page_jobs.append(job)
            if len(jobs) + len(page_jobs) >= max_results:
                break
        jobs += page_jobs

        # Newest-first ordering means an all-stale page implies every LATER page
        # is stale too — those rows would be dropped by is_fresh() at ingestion
        # anyway, so paging on just burns requests against someone else's server.
        # Two consecutive stale pages, not one, so a single odd page (all-undated,
        # or one bumped posting) can't truncate an otherwise-fresh crawl.
        stale_pages = stale_pages + 1 if _unstop_page_is_stale(page_jobs, now) else 0
        if stop_when_stale and stale_pages >= UNSTOP_STALE_PAGE_STREAK:
            logger.info(
                "Unstop %s/%r: stopping at page %d — %d consecutive pages older than %dd",
                opportunity,
                term,
                page,
                stale_pages,
                settings.max_job_age_days,
            )
            break

        last_page = paginator.get("last_page")
        if not isinstance(last_page, int) or page >= last_page:
            break
        page += 1
        # Deliberate throttle between pages. A full cold-start crawl is ~21
        # requests; spacing them keeps us a visibly polite caller rather than a
        # burst, which is the behaviour ADR-003's "no high-volume polling" is
        # really about.
        await asyncio.sleep(UNSTOP_PAGE_DELAY_SECONDS)

    return jobs


async def fetch_greenhouse() -> list[JobIn]:
    """Greenhouse Job Board API — free, unauthenticated, no key required.
    No salary data on this endpoint; left null rather than guessed."""
    jobs: list[JobIn] = []
    async with httpx.AsyncClient(timeout=30) as client:
        for board, name_override in _greenhouse_boards():
            url = f"{GREENHOUSE_BASE}/{board}/jobs"
            try:
                response = await client.get(url, params={"content": "true"})
                response.raise_for_status()
            except httpx.HTTPError as e:
                # One dead/renamed board shouldn't sink the whole refresh.
                logger.warning("Greenhouse board %r failed: %s", board, e)
                continue
            for r in response.json().get("jobs", []):
                jobs.append(
                    JobIn(
                        source="greenhouse",
                        external_id=str(r["id"]),
                        title=r.get("title", ""),
                        # Boards registered under a legal name ("Razorpay Software
                        # Private Limited") get an override; the rest read fine.
                        company=name_override or r.get("company_name"),
                        location=(r.get("location") or {}).get("name"),
                        description=_strip_html(r.get("content")),
                        redirect_url=r.get("absolute_url"),
                        posted_at=r.get("updated_at"),
                    )
                )
    return jobs


async def fetch_lever() -> list[JobIn]:
    """Lever Postings API — free, unauthenticated, no key required.
    No salary data on this endpoint; left null rather than guessed."""
    jobs: list[JobIn] = []
    async with httpx.AsyncClient(timeout=30) as client:
        for slug, company in _lever_companies():
            url = f"{LEVER_BASE}/{slug}"
            try:
                response = await client.get(url, params={"mode": "json"})
                response.raise_for_status()
            except httpx.HTTPError as e:
                logger.warning("Lever company %r failed: %s", slug, e)
                continue
            for r in response.json():
                created_at = r.get("createdAt")
                jobs.append(
                    JobIn(
                        source="lever",
                        external_id=r["id"],
                        title=r.get("text", ""),
                        company=company,
                        location=(r.get("categories") or {}).get("location"),
                        description=r.get("descriptionPlain"),
                        redirect_url=r.get("hostedUrl"),
                        posted_at=(
                            datetime.fromtimestamp(created_at / 1000, tz=timezone.utc) if created_at else None
                        ),
                    )
                )
    return jobs
