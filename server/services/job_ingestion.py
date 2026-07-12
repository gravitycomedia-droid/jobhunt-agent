import asyncio
import ipaddress
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
from services.job_sources import fetch_adzuna, fetch_greenhouse, fetch_jsearch, fetch_lever


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


async def refresh_job_pool() -> dict:
    """Fetch+dedup+embed+insert today's postings into the shared job pool
    (Brick 3/4). Plain function (not a route handler) so it can be called
    both from routers/jobs.py (behind auth) and jobs/daily_pipeline.py
    (the cron/batch path, which has no per-request auth dependency to
    resolve) without duplicating the logic in each caller.
    """
    adzuna_jobs, jsearch_jobs, greenhouse_jobs, lever_jobs = await asyncio.gather(
        fetch_adzuna(), fetch_jsearch(), fetch_greenhouse(), fetch_lever()
    )
    fetched = adzuna_jobs + jsearch_jobs + greenhouse_jobs + lever_jobs
    # Phase 1D: drop stale postings before dedup/embedding — one gate for
    # both sources.
    fetched = [job for job in fetched if is_fresh(job)]

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
