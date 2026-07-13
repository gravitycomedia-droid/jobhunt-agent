import asyncio
import ipaddress
import logging
import socket
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup

from config import settings
from db.supabase_client import supabase
from models.job import JobExtraction, JobIn
from services.dedup import is_duplicate, make_dedup_key
from services.embeddings import embed_text, embed_texts, job_embedding_text
from services.job_filter import is_relevant
from services.job_sources import (
    _locations,
    _roles,
    fetch_adzuna,
    fetch_greenhouse,
    fetch_indeed_apify,
    fetch_jsearch,
    fetch_lever,
    fetch_linkedin_apify,
    fetch_naukri_apify,
)

logger = logging.getLogger(__name__)


def is_fresh(job: JobIn, now: datetime | None = None) -> bool:
    """Phase 1D freshness gate: False for postings older than
    settings.max_job_age_days (job boards occasionally return years-old
    rows — the "2591d ago" bug). Unknown posted_at passes: the app renders
    it as "date unknown" rather than us dropping possibly-fresh jobs.
    """
    if job.posted_at is None:
        return True
    now = now or datetime.now(timezone.utc)
    posted = job.posted_at if job.posted_at.tzinfo else job.posted_at.replace(tzinfo=timezone.utc)
    return now - posted <= timedelta(days=settings.max_job_age_days)


class ManualJobFetchError(Exception):
    """The pasted URL couldn't be fetched or didn't look like a web page —
    distinct from JobExtractError (fetch succeeded, LLM extraction failed)
    so routers/jobs.py can give the user a more specific message."""


# Phase 14 / ADR-024 (SSRF): this server fetches a URL the USER chose, which
# means the user can aim our outbound requests at anything our network can
# reach — including things the public internet can't. On Cloud Run that's the
# metadata service at 169.254.169.254, which hands out service-account access
# tokens to anyone who asks from inside the box. "Fetch this job posting:
# http://169.254.169.254/computeMetadata/v1/..." would otherwise return the
# page text straight back to the caller via the extraction preview.
#
# So: only http(s), and only hosts that resolve to PUBLIC addresses.
_ALLOWED_SCHEMES = ("http", "https")
# Redirects are followed by hand (below) rather than by httpx, because a
# check-then-follow-redirects client validates only the FIRST url — a public
# host is free to 302 you to 169.254.169.254, and httpx would follow it.
_MAX_REDIRECTS = 5


def _assert_public_url(url: str) -> None:
    """Raises ManualJobFetchError unless `url` is http(s) and every address its
    hostname resolves to is publicly routable.

    `ip.is_global` is the whole check: it's False for RFC1918 private ranges
    (10/8, 172.16/12, 192.168/16), loopback (127/8, ::1), link-local
    (169.254/16 — the cloud metadata range — and fe80::/10), CGNAT (100.64/10),
    multicast, and the reserved blocks. Every address is checked, not just the
    first: a hostname with both a public A record and a private one must not
    slip through on the strength of the public one.

    Residual risk (documented, not solved): DNS rebinding. We resolve here and
    httpx resolves again when it connects, so a hostile resolver could return a
    public IP to this check and a private one microseconds later. Closing that
    needs pinning the connection to the vetted IP; it's a real gap, and out of
    proportion to a single-user portfolio app's threat model.
    """
    parsed = urlparse(url)
    if parsed.scheme not in _ALLOWED_SCHEMES:
        raise ManualJobFetchError(f"Only http and https links are supported (got '{parsed.scheme or 'no scheme'}')")

    host = parsed.hostname
    if not host:
        raise ManualJobFetchError("That doesn't look like a valid URL")

    try:
        addrinfo = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80))
    except socket.gaierror as e:
        raise ManualJobFetchError(f"Could not resolve that URL's host: {host}") from e

    for info in addrinfo:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global:
            raise ManualJobFetchError("That URL points to a private or internal address, which isn't allowed")


async def fetch_manual_job_text(url: str) -> str:
    """Add Job (frontend rebuild Phase 2): fetches one user-pasted URL and
    strips it to plain text for the LLM extraction prompt. Single
    user-supplied link, fetched on explicit request — not automated
    harvesting of a job board, which is what ADR-003's no-scraping stance
    is actually about (see DECISIONS.md ADR-009).

    ADR-024: every hop is re-validated against _assert_public_url, so neither
    the pasted URL nor anything it redirects to can reach our internal network.
    """
    headers = {"User-Agent": "Mozilla/5.0 (compatible; JobHuntAgent/1.0)"}
    current = url

    try:
        # follow_redirects=False: we follow them ourselves so each hop gets the
        # SSRF check. Timeout is per-request and unchanged at 15s.
        async with httpx.AsyncClient(timeout=15, follow_redirects=False) as client:
            for _ in range(_MAX_REDIRECTS + 1):
                _assert_public_url(current)
                response = await client.get(current, headers=headers)
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise ManualJobFetchError("That URL redirected without saying where")
                    # Relative Location headers are legal — resolve against the
                    # current URL before re-checking it.
                    current = str(response.url.join(location))
                    continue
                response.raise_for_status()
                break
            else:
                raise ManualJobFetchError("That URL redirected too many times")
    except httpx.HTTPError as e:
        raise ManualJobFetchError(f"Could not fetch that URL: {e}") from e

    content_type = response.headers.get("content-type", "")
    if "html" not in content_type:
        raise ManualJobFetchError(f"That URL didn't return a web page (content-type: {content_type or 'unknown'})")

    soup = BeautifulSoup(response.text, "html.parser")
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    text = soup.get_text(separator="\n", strip=True)
    if not text:
        raise ManualJobFetchError("That page had no readable text to extract from")
    return text


def insert_manual_job(extraction: JobExtraction, redirect_url: str | None = None, source: str = "manual") -> dict:
    """Add Job (frontend rebuild Phase 2): inserts a user-reviewed
    extraction into the shared job pool with source='manual'. Exact
    dedup_key match against a posting already in the pool (e.g. from
    Adzuna/JSearch) returns that existing row instead of creating a
    second one — see the exact-vs-fuzzy tradeoff noted below.

    `redirect_url` is optional and `source` overridable for the JD-paste
    resume builder (routers/jobs.py's `from-jd` flow, source='jd_paste') —
    a pasted/uploaded JD has no source link to redirect to.
    """
    # Exact dedup_key match only — is_duplicate()'s fuzzy check (used by
    # refresh_job_pool) only returns a bool, not which row matched, so it
    # can't tell us what to return here. A manual add is a deliberate
    # single-item user action, not a bulk-fetch flood, so skipping the
    # fuzzy pass trades a small chance of a near-duplicate row for never
    # returning the wrong job as if it were the match.
    dedup_key = make_dedup_key(extraction.title, extraction.company, extraction.location)
    existing = supabase.table("jobs").select("*").eq("dedup_key", dedup_key).limit(1).execute().data
    if existing:
        return existing[0]

    payload = {
        "source": source,
        "external_id": str(uuid.uuid4()),
        "title": extraction.title,
        "company": extraction.company,
        "location": extraction.location,
        "description": extraction.description,
        "salary_min": extraction.salary_min,
        "salary_max": extraction.salary_max,
        "redirect_url": redirect_url,
        "dedup_key": dedup_key,
        "embedding": embed_text(job_embedding_text(extraction.model_dump())),
    }
    return supabase.table("jobs").insert(payload).execute().data[0]


def _dedup_embed_insert(fetched: list[JobIn]) -> dict:
    """The shared back half of ingestion: freshness + relevance gates → dedup →
    batch-embed → upsert. Split out of refresh_job_pool() so
    refresh_scraped_sources() runs the identical path (ADR-003's amendment says
    scraped jobs get the same treatment as everything else — same dedup, same
    freshness rule, same embeddings), and so a fix to either only has to be made
    once.
    """
    # Phase 1D: drop stale postings before dedup/embedding — one gate for
    # every source.
    fresh = [job for job in fetched if is_fresh(job)]

    # Relevance gate (services/job_filter.py): fullstack/frontend/cloud-architect
    # internships and fresher roles, in Hyderabad/Bengaluru. It lives HERE rather
    # than in each fetcher because the sources have wildly different filtering
    # powers — Naukri filters by experience server-side, LinkedIn/Indeed only via
    # keywords, and Greenhouse/Lever not at all (they return a company's entire
    # board, every role and city). One gate, applied uniformly, is the only way
    # the pool means the same thing regardless of where a job came from.
    relevant = [job for job in fresh if is_relevant(job.title, job.location, job.description)]

    if len(fetched) != len(relevant):
        logger.info(
            "Ingestion gate: %d fetched → %d fresh (≤%dd) → %d relevant (role+entry-level+city)",
            len(fetched),
            len(fresh),
            settings.max_job_age_days,
            len(relevant),
        )
    fetched = relevant

    existing = (
        supabase.table("jobs")
        .select("title,company,location,dedup_key")
        .order("ingested_at", desc=True)
        .limit(500)
        .execute()
        .data
    )
    existing_keys = {row["dedup_key"] for row in existing}

    # Collect the new (non-duplicate) jobs first, embed them all in one
    # batched call, then insert — one embed_texts() call per refresh cycle
    # instead of one per job.
    new_jobs = []
    for job in fetched:
        dedup_key = make_dedup_key(job.title, job.company, job.location)
        if dedup_key in existing_keys or is_duplicate(job, existing):
            continue
        existing_keys.add(dedup_key)
        existing.append({"title": job.title, "company": job.company, "location": job.location, "dedup_key": dedup_key})
        new_jobs.append((job, dedup_key))

    embeddings = embed_texts([job_embedding_text(job.model_dump(mode="json")) for job, _ in new_jobs])

    payloads = []
    for (job, dedup_key), embedding in zip(new_jobs, embeddings):
        payload = job.model_dump(mode="json")
        payload["dedup_key"] = dedup_key
        payload["embedding"] = embedding
        payloads.append(payload)

    # One batched upsert instead of one insert() round-trip per row — with
    # Greenhouse/Lever added (job source expansion, ADR-018), a single
    # refresh can find 200+ new rows, and 200+ sequential HTTP calls to
    # Supabase was enough on its own to blow past the app's 90s client
    # timeout. ignore_duplicates=True does the same job the old per-row
    # try/except did (skip a dedup_key collision from a concurrent refresh
    # race without erroring), just as one request instead of N.
    inserted = 0
    if payloads:
        result = supabase.table("jobs").upsert(payloads, on_conflict="dedup_key", ignore_duplicates=True).execute()
        inserted = len(result.data)

    return {"fetched": len(fetched), "inserted": inserted}


async def refresh_job_pool() -> dict:
    """Fetch+dedup+embed+insert today's postings into the shared job pool
    (Brick 3/4). Plain function (not a route handler) so it can be called
    both from routers/jobs.py (behind auth) and jobs/daily_pipeline.py
    (the cron/batch path, which has no per-request auth dependency to
    resolve) without duplicating the logic in each caller.

    Free sources only. The Apify-scraped sources bill per result, so they are
    deliberately NOT here — see refresh_scraped_sources().
    """
    adzuna_jobs, jsearch_jobs, greenhouse_jobs, lever_jobs = await asyncio.gather(
        fetch_adzuna(), fetch_jsearch(), fetch_greenhouse(), fetch_lever()
    )
    return _dedup_embed_insert(adzuna_jobs + jsearch_jobs + greenhouse_jobs + lever_jobs)


# Weekday gate for the paid sources. `datetime.weekday()` is 0=Mon..6=Sun.
_WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def _is_due(weekdays: str, now: datetime | None = None) -> bool:
    """True when today falls in a comma-separated weekday list. Empty → never."""
    allowed = {d.strip().lower() for d in weekdays.split(",") if d.strip()}
    if not allowed:
        return False
    return _WEEKDAYS[(now or datetime.now(timezone.utc)).weekday()] in allowed


def _scraped_sources_due(now: datetime | None = None) -> list[tuple[str, object, int]]:
    """The (name, fetcher, cap) triples that should run today.

    Each source carries its own cadence and its own result cap, because they
    cost 10x different amounts per job: LinkedIn is cheap enough to run three
    times a week, Naukri is priciest and runs weekly. A source is skipped when
    its actor ID is unset (off) or today isn't one of its weekdays.
    """
    configured = [
        (
            "linkedin",
            settings.apify_linkedin_actor_id,
            fetch_linkedin_apify,
            settings.apify_linkedin_weekdays,
            settings.apify_linkedin_max_results,
        ),
        (
            "indeed",
            settings.apify_indeed_actor_id,
            fetch_indeed_apify,
            settings.apify_indeed_weekdays,
            settings.apify_indeed_max_results,
        ),
        (
            "naukri",
            settings.apify_naukri_actor_id,
            fetch_naukri_apify,
            settings.apify_naukri_weekdays,
            settings.apify_naukri_max_results,
        ),
    ]
    return [
        (name, fetcher, cap)
        for name, actor_id, fetcher, weekdays, cap in configured
        if actor_id.strip() and _is_due(weekdays, now)
    ]


def should_scrape_today(now: datetime | None = None) -> bool:
    """True when ANY scraped source is due today — the cheap check the daily
    pipeline uses to skip the whole paid path without building task lists."""
    return bool(settings.apify_api_token) and bool(_scraped_sources_due(now))


async def refresh_scraped_sources(now: datetime | None = None) -> dict:
    """The paid half of ingestion: LinkedIn/Indeed/Naukri via Apify (ADR-003,
    amended). Same fetch→dedup→embed→insert shape as refresh_job_pool(), but on
    a per-source cadence and never on a user-triggered path.

    Guards on spend, because every result here costs money:
      1. No token → no-op. (The kill switch: unset APIFY_API_TOKEN.)
      2. An empty actor ID or an off-cadence weekday skips that source entirely.
      3. Results per (role × location) are capped per-source.
      4. Concurrency is bounded — see the semaphore below.
    """
    if not settings.apify_api_token:
        logger.info("Scraped sources skipped: APIFY_API_TOKEN not set")
        return {"fetched": 0, "inserted": 0, "calls": 0, "skipped": "no_token"}

    due = _scraped_sources_due(now)
    if not due:
        logger.info("Scraped sources: none due today")
        return {"fetched": 0, "inserted": 0, "calls": 0, "skipped": "not_due"}

    roles, locations = _roles(), _locations()
    per_source_calls = len(roles) * len(locations)
    calls = per_source_calls * len(due)
    max_results = sum(per_source_calls * cap for _, _, cap in due)

    # Logged up front (not tallied afterwards) so the bill is predictable from
    # the logs BEFORE the money is spent, not merely explicable after.
    logger.info(
        "Scraped sources due today: %s → %d Apify calls (%d roles × %d locations × %d sources), "
        "≤%d billable results, ≤%d concurrent",
        ", ".join(f"{name}(≤{cap})" for name, _, cap in due),
        calls,
        len(roles),
        len(locations),
        len(due),
        max_results,
        settings.apify_max_concurrent_runs,
    )

    # Each Apify run reserves ~4GB and the free plan ceiling is 16GB in flight.
    # Unbounded gather() asks for 24-48GB at once and Apify 402s the overflow —
    # which looks exactly like "out of credit" but isn't (observed live at $0.84
    # of a $5 budget). The semaphore is what makes the fan-out safe.
    semaphore = asyncio.Semaphore(settings.apify_max_concurrent_runs)

    async def _guarded(fetcher, role: str, location: str, cap: int) -> list[JobIn]:
        async with semaphore:
            return await fetcher(role, location, cap)

    tasks = [
        _guarded(fetcher, role, location, cap)
        for _, fetcher, cap in due
        for role in roles
        for location in locations
    ]
    # return_exceptions=True: run_actor() already swallows HTTP failures, but a
    # mapping bug on one actor's payload must not lose the other sources' jobs
    # — one bad source degrades to zero jobs, it doesn't sink the run.
    results = await asyncio.gather(*tasks, return_exceptions=True)

    fetched: list[JobIn] = []
    for result in results:
        if isinstance(result, Exception):
            logger.warning("A scraped source raised: %s: %s", type(result).__name__, result)
            continue
        fetched.extend(result)

    summary = _dedup_embed_insert(fetched)
    summary["calls"] = calls
    logger.info(
        "Scraped sources: %d fetched, %d inserted after dedup/freshness",
        summary["fetched"],
        summary["inserted"],
    )
    return summary


def backfill_job_embeddings() -> dict:
    """One-off catch-up for jobs ingested before Brick 4 added embedding.
    Safe to call repeatedly — only touches rows where embedding is null.
    """
    rows = supabase.table("jobs").select("id,title,company,description").is_("embedding", "null").execute().data
    if not rows:
        return {"backfilled": 0}

    embeddings = embed_texts([job_embedding_text(row) for row in rows])
    for row, embedding in zip(rows, embeddings):
        supabase.table("jobs").update({"embedding": embedding}).eq("id", row["id"]).execute()

    return {"backfilled": len(rows)}
