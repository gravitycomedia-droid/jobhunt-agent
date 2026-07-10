from datetime import datetime, timedelta, timezone

from db.supabase_client import supabase
from services.job_ingestion import backfill_job_embeddings, refresh_job_pool
from services.llm import FollowupError, LlmApiError, generate_followup_draft
from services.matching import DEFAULT_RERANK_LIMIT, rerank_shortlist
from services.notify import send_push_notification

# An application sitting in 'applied' this long with no reply is a
# follow-up candidate (docs/PROMPTS.md section 4: "no response after
# 7+ days").
FOLLOWUP_AFTER_DAYS = 7


def _draft_pending_followups(profile: dict) -> int:
    """Drafts a follow-up email for every 'applied' application on this
    profile that's been waiting 7+ days and doesn't already have one —
    safe to call repeatedly, since already-drafted applications are
    skipped.
    """
    headline = profile.get("headline") or profile.get("name") or "a candidate"

    cutoff = (datetime.now(timezone.utc) - timedelta(days=FOLLOWUP_AFTER_DAYS)).isoformat()
    candidates = (
        supabase.table("applications")
        .select("*")
        .eq("profile_id", profile["id"])
        .eq("state", "applied")
        .is_("followup_drafted_at", "null")
        .lte("state_changed_at", cutoff)
        .execute()
        .data
    )
    if not candidates:
        return 0

    job_ids = [c["job_id"] for c in candidates]
    jobs = supabase.table("jobs").select("id,title,company").in_("id", job_ids).execute().data
    jobs_by_id = {j["id"]: j for j in jobs}

    drafted = 0
    for app in candidates:
        job = jobs_by_id.get(app["job_id"])
        if job is None:
            continue
        try:
            draft = generate_followup_draft(
                job_title=job["title"],
                company=job.get("company") or "the company",
                applied_date=app["state_changed_at"][:10],
                headline=headline,
                profile_id=profile["id"],
            )
        except (FollowupError, LlmApiError):
            # One job's draft failing shouldn't stop the rest of the batch —
            # it'll retry on tomorrow's pipeline run since followup_drafted_at
            # stays null.
            continue
        supabase.table("applications").update(
            {
                "followup_subject": draft.subject,
                "followup_body": draft.body,
                "followup_drafted_at": datetime.now(timezone.utc).isoformat(),
            }
        ).eq("id", app["id"]).execute()
        drafted += 1

    return drafted


def _process_profile(profile: dict) -> dict:
    """Brick 9: the per-user half of the agent loop — re-rank that user's
    shortlist, draft their stale follow-ups, and push if either produced
    something. Shared across the all-users batch (run_daily_pipeline_for_all)
    and the single-user manual trigger (run_daily_pipeline_for_profile) so
    the two never drift.
    """
    # Phase 4 Settings: both toggles gate calls that already ran
    # unconditionally before migration 008 — a missing/null column (or a
    # profile row from before the migration) reads as "on" to preserve
    # existing behavior.
    prefs = profile.get("notification_prefs") or {}

    rerank_result = rerank_shortlist(profile, limit=DEFAULT_RERANK_LIMIT)
    followups_drafted = _draft_pending_followups(profile) if prefs.get("followup_nudge", True) else 0

    apply_worthy = rerank_result["reranked"]
    if (apply_worthy or followups_drafted) and prefs.get("alerts", True):
        send_push_notification(
            "Job-Hunt Agent ran",
            f"{apply_worthy} newly scored, {followups_drafted} follow-up draft(s) ready.",
            token=profile.get("fcm_token"),
        )

    return {"matches_reranked": apply_worthy, "followups_drafted": followups_drafted}


async def _refresh_and_backfill() -> dict:
    """The shared, non-per-user half of the agent loop: the job pool has
    no owner, so this only ever needs to run once per pipeline invocation
    regardless of how many beta users get processed after it.
    """
    refresh_result = await refresh_job_pool()
    backfill_result = backfill_job_embeddings()
    return {
        "jobs_fetched": refresh_result["fetched"],
        "jobs_inserted": refresh_result["inserted"],
        "embeddings_backfilled": backfill_result["backfilled"],
    }


async def run_daily_pipeline_for_all() -> dict:
    """The Render cron path (Brick 8/9): fetch+dedup+embed today's jobs
    once, then run the per-user half of the loop for every beta user with
    a profile. Intended to run on a schedule (POST /pipeline/run, guarded
    by X-Pipeline-Secret since there's no per-user session to authenticate
    a cron job with), but idempotent enough to call manually any time.
    """
    summary = await _refresh_and_backfill()

    profiles = supabase.table("profiles").select("*").execute().data
    matches_reranked = 0
    followups_drafted = 0
    for profile in profiles:
        result = _process_profile(profile)
        matches_reranked += result["matches_reranked"]
        followups_drafted += result["followups_drafted"]

    summary["profiles_processed"] = len(profiles)
    summary["matches_reranked"] = matches_reranked
    summary["followups_drafted"] = followups_drafted
    return summary


async def run_daily_pipeline_for_profile(profile: dict) -> dict:
    """The authenticated "Run agent now" path — refreshes the shared job
    pool (the caller is waiting for fresh listings) but only processes
    their own profile, not every beta user's.
    """
    summary = await _refresh_and_backfill()
    summary.update(_process_profile(profile))
    return summary
