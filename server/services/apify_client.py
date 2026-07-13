"""Generic Apify actor runner (ADR-003, amended 2026-07-13).

One function, deliberately dumb: it runs an actor and hands back whatever
rows the actor produced. It knows nothing about jobs, LinkedIn, or salary
parsing — the per-source input building and output mapping lives in
services/job_sources.py, so swapping an actor never means touching this file.

Error philosophy matches fetch_adzuna()'s: a failing source logs a warning and
yields nothing. It never raises, because the daily pipeline fans out across
several sources and one flaky/expired/rate-limited actor must not sink the
rest of the run.
"""

import logging
from typing import Any

import httpx

from config import settings

logger = logging.getLogger(__name__)

APIFY_BASE = "https://api.apify.com/v2/acts"


async def run_actor(actor_id: str, run_input: dict[str, Any], timeout_s: int = 120) -> list[dict]:
    """Runs an Apify actor synchronously and returns its dataset items.

    `run-sync-get-dataset-items` blocks until the actor finishes and responds
    with the dataset rows directly — one HTTP call instead of the
    start-run → poll-status → fetch-dataset dance. Apify caps a sync run at
    300s server-side, so `timeout_s` should stay under that; the default 120s
    is the pragmatic ceiling for the small `maxResults` caps we send.

    Returns [] on every failure mode (no token, no actor, non-2xx, timeout,
    malformed JSON) — never raises.
    """
    if not settings.apify_api_token:
        logger.warning("Apify actor %s skipped: APIFY_API_TOKEN is not set", actor_id)
        return []
    if not actor_id:
        logger.warning("Apify run skipped: no actor ID configured for this source")
        return []

    url = f"{APIFY_BASE}/{actor_id}/run-sync-get-dataset-items"
    # Token goes in the header, not the ?token= query param the Apify docs
    # reach for first: query strings land in access logs and exception traces,
    # and this one is a live credential (golden rule 1). Same auth, no leak.
    headers = {"Authorization": f"Bearer {settings.apify_api_token}"}

    try:
        async with httpx.AsyncClient(timeout=timeout_s) as client:
            response = await client.post(url, json=run_input, headers=headers)
            response.raise_for_status()
            items = response.json()
    except httpx.TimeoutException:
        logger.warning("Apify actor %s timed out after %ss", actor_id, timeout_s)
        return []
    except httpx.HTTPStatusError as e:
        # Log the status, never the body: an auth-failure body can echo the
        # token back, and there's no rule saying an actor's error payload is
        # safe to dump into logs.
        logger.warning("Apify actor %s failed with HTTP %s", actor_id, e.response.status_code)
        return []
    except httpx.HTTPError as e:
        logger.warning("Apify actor %s request failed: %s", actor_id, type(e).__name__)
        return []
    except ValueError:
        # 200 with a body that isn't JSON. Rare, but an actor that half-crashes
        # can do this, and .json() raising here would otherwise escape as an
        # unhandled error mid-pipeline.
        logger.warning("Apify actor %s returned a non-JSON body", actor_id)
        return []

    # The endpoint is documented to return a JSON array, but a misbehaving actor
    # can return an object (often an error envelope). Don't trust it — the whole
    # point of validating here is that we don't control the actor's code.
    if not isinstance(items, list):
        logger.warning("Apify actor %s returned %s, expected a list of items", actor_id, type(items).__name__)
        return []

    rows = [item for item in items if isinstance(item, dict)]
    if len(rows) != len(items):
        logger.warning("Apify actor %s returned %d non-dict items, skipped", actor_id, len(items) - len(rows))

    logger.info("Apify actor %s returned %d items", actor_id, len(rows))
    return rows
