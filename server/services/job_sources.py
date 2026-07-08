import logging

import httpx

from config import settings
from models.job import JobIn

logger = logging.getLogger(__name__)

ADZUNA_BASE = "https://api.adzuna.com/v1/api/jobs"
JSEARCH_URL = "https://jsearch.p.rapidapi.com/search-v2"


def _roles() -> list[str]:
    return [r.strip() for r in settings.target_roles.split(",") if r.strip()]


def _locations() -> list[str]:
    return [loc.strip() for loc in settings.target_locations.split(",") if loc.strip()]


async def fetch_adzuna() -> list[JobIn]:
    jobs: list[JobIn] = []
    async with httpx.AsyncClient(timeout=30) as client:
        for role in _roles():
            for location in _locations():
                url = f"{ADZUNA_BASE}/{settings.adzuna_country}/search/1"
                params = {
                    "app_id": settings.adzuna_app_id,
                    "app_key": settings.adzuna_app_key,
                    "what": role,
                    "where": location,
                    "results_per_page": 20,
                }
                try:
                    response = await client.get(url, params=params)
                    response.raise_for_status()
                except httpx.HTTPError as e:
                    # One flaky query (timeout, rate limit) shouldn't sink the
                    # whole refresh cycle — skip it and keep going.
                    logger.warning("Adzuna query failed for %r/%r: %s", role, location, e)
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
                            redirect_url=j.get("job_apply_link"),
                            posted_at=j.get("job_posted_at_datetime_utc"),
                        )
                    )
    return jobs
