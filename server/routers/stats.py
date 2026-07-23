from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query

from config import settings
from db.supabase_client import supabase
from services.activity import build_activity_feed
from services.auth import get_current_profile
from services.cost_stats import summarize_costs
from services.rate_limit import enforce_rate_limit
from services.score_history import compute_score_history
from services.skill_growth import get_skill_growth

router = APIRouter(prefix="/stats", tags=["stats"])


@router.get("/score-history")
async def get_score_history(profile: dict = Depends(get_current_profile)):
    """Phase 4: the fit-score delta chip + sparkline (R-D). Reads this profile's
    score_snapshots and returns the current point, a day-over-day delta against
    the latest snapshot >=24h older (None until one exists — the client then hides
    the chip rather than showing a fabricated 0), and the series for the sparkline.
    See services/score_history.py."""
    rows = (
        supabase.table("score_snapshots")
        .select("top_fit_score,avg_fit_score,match_count,captured_at")
        .eq("profile_id", profile["id"])
        .order("captured_at", desc=True)
        .limit(60)
        .execute()
        .data
    )
    return {"data": compute_score_history(rows), "error": None}


@router.get("/costs")
async def get_cost_stats(profile: dict = Depends(get_current_profile)):
    """Phase 3: this-calendar-month LLM cost/usage for the caller, broken down
    by task and — since ADR-023 put DeepSeek alongside Gemini — by provider.
    What CostStatsScreen renders. See services/cost_stats.py for the
    (approximate) pricing this is built on.
    """
    month_start = datetime.now(timezone.utc).replace(day=1, hour=0, minute=0, second=0, microsecond=0).isoformat()
    rows = (
        supabase.table("llm_calls")
        .select("task,provider,model,tokens_in,tokens_out")
        .eq("profile_id", profile["id"])
        .gte("created_at", month_start)
        .execute()
        .data
    )
    return {"data": summarize_costs(rows), "error": None}


@router.get("/activity")
async def get_activity(limit: int = Query(30, le=100), profile: dict = Depends(get_current_profile)):
    """Phase 3: "what the agent did on your behalf" — merges application
    stage changes, follow-up drafts, and resume tailoring events for the
    caller, newest first. See services/activity.py for why this reads
    existing tables instead of a dedicated activity-log one.
    """
    profile_id = profile["id"]
    apps = supabase.table("applications").select("*").eq("profile_id", profile_id).execute().data
    tailored = supabase.table("tailored_resumes").select("*").eq("profile_id", profile_id).execute().data

    job_ids = {a["job_id"] for a in apps} | {t["job_id"] for t in tailored}
    jobs_by_id: dict[str, dict] = {}
    if job_ids:
        jobs = supabase.table("jobs").select("id,title,company").in_("id", list(job_ids)).execute().data
        jobs_by_id = {j["id"]: j for j in jobs}

    apps_joined = [{**a, "job": jobs_by_id.get(a["job_id"])} for a in apps]
    tailored_joined = [{**t, "job": jobs_by_id.get(t["job_id"])} for t in tailored]

    feed = build_activity_feed(apps_joined, tailored_joined)[:limit]
    return {"data": feed, "error": None}


@router.get(
    "/skill-growth",
    dependencies=[
        Depends(enforce_rate_limit("skill_growth", settings.rate_limit_skill_growth, settings.rate_limit_window_seconds))
    ],
)
async def get_skill_growth_stats(profile: dict = Depends(get_current_profile)):
    """Phase 4: skills-to-learn aggregated from the caller's real match
    gaps, with LLM-suggested courses/projects — what SkillGrowthScreen
    renders. See services/skill_growth.py for how frequency is computed."""
    return {"data": get_skill_growth(profile), "error": None}
