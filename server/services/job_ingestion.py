import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import httpx
from bs4 import BeautifulSoup

from config import settings
from db.supabase_client import supabase
from models.job import JobExtraction, JobIn
from services.dedup import is_duplicate, make_dedup_key
from services.embeddings import embed_text, embed_texts, job_embedding_text
from services.job_sources import fetch_adzuna, fetch_jsearch


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


async def fetch_manual_job_text(url: str) -> str:
    """Add Job (frontend rebuild Phase 2): fetches one user-pasted URL and
    strips it to plain text for the LLM extraction prompt. Single
    user-supplied link, fetched on explicit request — not automated
    harvesting of a job board, which is what ADR-003's no-scraping stance
    is actually about (see DECISIONS.md ADR-009).
    """
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            response = await client.get(url, headers={"User-Agent": "Mozilla/5.0 (compatible; JobHuntAgent/1.0)"})
            response.raise_for_status()
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


def insert_manual_job(extraction: JobExtraction, redirect_url: str) -> dict:
    """Add Job (frontend rebuild Phase 2): inserts a user-reviewed
    extraction into the shared job pool with source='manual'. Exact
    dedup_key match against a posting already in the pool (e.g. from
    Adzuna/JSearch) returns that existing row instead of creating a
    second one — see the exact-vs-fuzzy tradeoff noted below.
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
        "source": "manual",
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
    adzuna_jobs, jsearch_jobs = await asyncio.gather(fetch_adzuna(), fetch_jsearch())
    fetched = adzuna_jobs + jsearch_jobs
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

    inserted = 0
    for (job, dedup_key), embedding in zip(new_jobs, embeddings):
        payload = job.model_dump(mode="json")
        payload["dedup_key"] = dedup_key
        payload["embedding"] = embedding
        try:
            supabase.table("jobs").insert(payload).execute()
        except Exception:
            # Most likely the dedup_key unique constraint firing on a race
            # between concurrent refreshes — safe to skip, not a real error.
            continue
        inserted += 1

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
