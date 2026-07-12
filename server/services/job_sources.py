import html
import logging
from datetime import datetime, timezone

import httpx
from bs4 import BeautifulSoup

from config import settings
from models.job import JobIn

logger = logging.getLogger(__name__)

ADZUNA_BASE = "https://api.adzuna.com/v1/api/jobs"
JSEARCH_URL = "https://jsearch.p.rapidapi.com/search-v2"
GREENHOUSE_BASE = "https://boards-api.greenhouse.io/v1/boards"
LEVER_BASE = "https://api.lever.co/v0/postings"

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
