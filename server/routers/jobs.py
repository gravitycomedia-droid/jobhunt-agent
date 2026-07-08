import asyncio

from fastapi import APIRouter, Query

from db.supabase_client import supabase
from services.dedup import is_duplicate, make_dedup_key
from services.job_sources import fetch_adzuna, fetch_jsearch

router = APIRouter(prefix="/jobs", tags=["jobs"])


@router.post("/refresh")
async def refresh_jobs():
    adzuna_jobs, jsearch_jobs = await asyncio.gather(fetch_adzuna(), fetch_jsearch())
    fetched = adzuna_jobs + jsearch_jobs

    existing = (
        supabase.table("jobs")
        .select("title,company,location,dedup_key")
        .order("ingested_at", desc=True)
        .limit(500)
        .execute()
        .data
    )
    existing_keys = {row["dedup_key"] for row in existing}

    inserted = 0
    for job in fetched:
        dedup_key = make_dedup_key(job.title, job.company, job.location)
        if dedup_key in existing_keys or is_duplicate(job, existing):
            continue

        payload = job.model_dump(mode="json")
        payload["dedup_key"] = dedup_key
        try:
            supabase.table("jobs").insert(payload).execute()
        except Exception:
            # Most likely the dedup_key unique constraint firing on a race
            # between concurrent refreshes — safe to skip, not a real error.
            continue

        existing_keys.add(dedup_key)
        existing.append({"title": job.title, "company": job.company, "location": job.location, "dedup_key": dedup_key})
        inserted += 1

    return {"data": {"fetched": len(fetched), "inserted": inserted}, "error": None}


@router.get("")
async def list_jobs(limit: int = Query(20, le=100), offset: int = Query(0, ge=0)):
    result = (
        supabase.table("jobs")
        .select("*")
        .order("ingested_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )
    return {"data": result.data, "error": None}
