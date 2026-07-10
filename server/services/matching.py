from db.supabase_client import supabase
from services.llm import rerank_job

# Stage 2 only re-ranks the top N of the stage-1 shortlist (ADR-001) —
# sending every embedded job to the LLM would defeat the point of stage 1.
DEFAULT_RERANK_LIMIT = 20


def _stage1_shortlist(profile_id: str, limit: int) -> list[dict]:
    ranked = supabase.rpc("match_jobs_by_similarity", {"p_profile_id": profile_id, "p_limit": limit}).execute().data
    if not ranked:
        return []
    job_ids = [row["job_id"] for row in ranked]
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {job["id"]: job for job in jobs}
    return [{**jobs_by_id[row["job_id"]], "similarity": row["similarity"]} for row in ranked if row["job_id"] in jobs_by_id]


def rerank_shortlist(profile: dict, limit: int = DEFAULT_RERANK_LIMIT) -> dict:
    """Runs stage 1 (similarity) then stage 2 (LLM re-rank) for the top
    `limit` jobs, skipping any (profile, job) pair already cached in
    `matches` — the table's unique constraint makes each job ranked once
    per profile, so re-running this is cheap and safe to call repeatedly.
    Brick 9: takes the caller's profile directly (from services/auth.py's
    get_current_profile, or looped per-user by the daily pipeline) instead
    of assuming a single global profile.
    """
    profile_id = profile["id"]
    shortlist = _stage1_shortlist(profile_id, limit)
    if not shortlist:
        return {"reranked": 0, "skipped": 0}

    job_ids = [job["id"] for job in shortlist]
    already_ranked = (
        supabase.table("matches")
        .select("job_id")
        .eq("profile_id", profile_id)
        .in_("job_id", job_ids)
        .execute()
        .data
    )
    ranked_job_ids = {row["job_id"] for row in already_ranked}

    reranked = 0
    for job in shortlist:
        if job["id"] in ranked_job_ids:
            continue
        result = rerank_job(profile, job, profile_id=profile_id)
        supabase.table("matches").insert(
            {
                "profile_id": profile_id,
                "job_id": job["id"],
                "similarity": job["similarity"],
                "fit_score": result.fit_score,
                "strengths": result.strengths,
                "gaps": result.gaps,
                "compensators": result.compensators,
                "verdict": result.verdict,
                "one_line_reason": result.one_line_reason,
            }
        ).execute()
        reranked += 1

    return {"reranked": reranked, "skipped": len(shortlist) - reranked}


def get_ranked_matches(profile: dict, limit: int = 50) -> list[dict]:
    """Reads cached stage-2 results (Brick 5's persisted output) joined with
    their job rows, ordered best-fit first. Call rerank_shortlist() first
    to populate/refresh the cache."""
    matches = (
        supabase.table("matches")
        .select("*")
        .eq("profile_id", profile["id"])
        .order("fit_score", desc=True)
        .limit(limit)
        .execute()
        .data
    )
    if not matches:
        return []

    job_ids = [m["job_id"] for m in matches]
    jobs = supabase.table("jobs").select("*").in_("id", job_ids).execute().data
    jobs_by_id = {job["id"]: job for job in jobs}

    results = []
    for m in matches:
        job = jobs_by_id.get(m["job_id"])
        if job is None:
            continue
        results.append(
            {
                **job,
                "similarity": m["similarity"],
                "fit_score": m["fit_score"],
                "strengths": m["strengths"],
                "gaps": m["gaps"],
                "compensators": m["compensators"],
                "verdict": m["verdict"],
                "one_line_reason": m["one_line_reason"],
            }
        )
    return results
