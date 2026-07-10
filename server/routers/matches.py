from fastapi import APIRouter, Depends, Query

from db.supabase_client import supabase
from services.auth import get_current_profile
from services.matching import DEFAULT_RERANK_LIMIT, get_ranked_matches, rerank_shortlist

router = APIRouter(prefix="/matches", tags=["matches"])


@router.get("/shortlist")
async def shortlist(limit: int = Query(50, le=100), profile: dict = Depends(get_current_profile)):
    """Stage 1 of the two-stage RAG match (ADR-001): pgvector cosine
    similarity between the caller's profile and every embedded job, via
    the match_jobs_by_similarity() SQL function from migration 001.
    Stage 2 (LLM re-rank) lives at POST /matches/rerank + GET /matches.
    """
    ranked = supabase.rpc("match_jobs_by_similarity", {"p_profile_id": profile["id"], "p_limit": limit}).execute().data
    if not ranked:
        return {"data": [], "error": None}

    job_ids = [row["job_id"] for row in ranked]
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {job["id"]: job for job in jobs}

    shortlisted = []
    for row in ranked:
        job = jobs_by_id.get(row["job_id"])
        if job is None:
            continue
        shortlisted.append({**job, "similarity": row["similarity"]})

    return {"data": shortlisted, "error": None}


@router.post("/rerank")
async def rerank(limit: int = Query(DEFAULT_RERANK_LIMIT, le=50), profile: dict = Depends(get_current_profile)):
    """Stage 2 of the two-stage RAG match (ADR-001, Brick 5): LLM re-ranks
    the top `limit` jobs from the stage-1 shortlist and caches results in
    `matches`. Safe to call repeatedly — already-ranked (profile, job)
    pairs are skipped, not re-scored.
    """
    result = rerank_shortlist(profile, limit=limit)
    return {"data": result, "error": None}


@router.get("")
async def matches(limit: int = Query(50, le=100), profile: dict = Depends(get_current_profile)):
    """Cached stage-2 results, best fit first. Call POST /matches/rerank
    first (or after refreshing jobs) to populate/refresh this."""
    results = get_ranked_matches(profile, limit=limit)
    return {"data": results, "error": None}
