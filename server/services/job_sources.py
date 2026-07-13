import html
import logging
import re
from datetime import datetime, timezone
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
                # empirically against /v1/api/jobs/in/categories) — appending
                # "intern" to the free-text query is the only way to surface
                # internship-labeled postings alongside full-time ones.
                for query in (role, f"{role} intern"):
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
                    "query": f"{role} in {location}",
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
    # This actor takes LinkedIn search URLs, not role/location fields — so we
    # build the URL LinkedIn's own job search would produce.
    return f"{LINKEDIN_JOBS_SEARCH}?{urlencode({'keywords': role, 'location': location})}"


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
    rows = await run_actor(
        settings.apify_indeed_actor_id,
        {
            "position": role,
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
