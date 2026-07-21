import logging
from datetime import datetime, timedelta, timezone

from config import settings
from db.supabase_client import supabase
from services.ingestion_health import record_and_alert_ingestion
from services.job_ingestion import (
    backfill_job_embeddings,
    refresh_job_pool,
    refresh_scraped_sources,
    refresh_unstop,
    should_scrape_today,
)
from services.llm import FollowupError, LlmApiError, generate_followup_draft
from services.matching import DEFAULT_RERANK_LIMIT, rerank_shortlist
from services.notify import send_push_notification

logger = logging.getLogger(__name__)

# Per-source detail the ingestion health log consumes internally. Stripped from
# the pipeline's returned summary so it never leaks into the API response — the
# app's summary stays the flat counts it already renders.
_INTERNAL_SUMMARY_KEYS = ("free_by_source", "free_errors", "scraped_by_source", "scraped_errors")


def _strip_internal(summary: dict) -> dict:
    for key in _INTERNAL_SUMMARY_KEYS:
        summary.pop(key, None)
    return summary


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
        # Per-source detail for the cron's ingestion health log (plan 15,
        # Phase F). Carried through but ignored by the per-user path, which
        # doesn't log health — see run_daily_pipeline_for_all.
        "free_by_source": refresh_result.get("by_source", {}),
        "free_errors": refresh_result.get("errors", {}),
    }


async def _refresh_scraped_if_due() -> dict:
    """The scraped sources, gathered here so they run ONLY from
    run_daily_pipeline_for_all — the cron path — and never from
    _refresh_and_backfill(), which is shared with run_daily_pipeline_for_profile()
    (the app's "Run agent now" button). Putting scraping in the shared helper
    would let any user spend real Apify money — or hit Unstop — on demand by
    tapping a button; the rate limiter would cap the rate, not the fact of it.

    Two independently-gated sub-paths, each wrapped so its failure loses only its
    own jobs, never the day's re-ranks and follow-ups:
      - Apify (LinkedIn/Indeed/Naukri/Internshala): per-source weekday cadence,
        because each result costs money.
      - Unstop: free/direct, so no cost-cadence — runs every cron day when
        enable_india_sources is on. refresh_unstop() self-gates on that flag.
    """
    summary = {"scraped_fetched": 0, "scraped_inserted": 0, "scraped_by_source": {}, "scraped_errors": {}}

    def _merge(result: dict) -> None:
        summary["scraped_fetched"] += result.get("fetched", 0)
        summary["scraped_inserted"] += result.get("inserted", 0)
        summary["scraped_by_source"].update(result.get("by_source", {}))
        summary["scraped_errors"].update(result.get("errors", {}))

    # --- Apify sources (cost-gated by weekday cadence) ---
    if should_scrape_today():
        try:
            _merge(await refresh_scraped_sources())
        except Exception as e:
            # refresh_scraped_sources() already swallows per-source failures, so
            # reaching here means something systemic (Supabase down mid-upsert, an
            # embedding failure). Log and continue — the "bad token doesn't crash
            # the daily pipeline" acceptance criterion.
            logger.exception("Apify scraped-source refresh failed, continuing pipeline: %s", e)
    else:
        logger.info(
            "Apify scraped sources: none due today (linkedin=%s indeed=%s naukri=%s internshala=%s)",
            settings.apify_linkedin_weekdays or "off",
            settings.apify_indeed_weekdays or "off",
            settings.apify_naukri_weekdays or "off",
            settings.apify_internshala_weekdays if settings.enable_india_sources else "off",
        )

    # --- Unstop (free/direct, India-source-gated) ---
    try:
        _merge(await refresh_unstop())
    except Exception as e:
        logger.exception("Unstop refresh failed, continuing pipeline: %s", e)

    return summary


async def run_daily_pipeline_for_all() -> dict:
    """The Render cron path (Brick 8/9): fetch+dedup+embed today's jobs
    once, then run the per-user half of the loop for every beta user with
    a profile. Intended to run on a schedule (POST /pipeline/run, guarded
    by X-Pipeline-Secret since there's no per-user session to authenticate
    a cron job with), but idempotent enough to call manually any time.
    """
    summary = await _refresh_and_backfill()
    scraped = await _refresh_scraped_if_due()
    summary.update(scraped)

    # Ingestion health (plan 15, Phase F) — cron-only, ON PURPOSE. This is the
    # one authoritative daily run where "a source returned nothing" is a real
    # signal; logging it from the per-user "Run agent now" path instead would
    # both spam the ops inbox and pollute the trailing-average baseline with
    # partial intra-day runs. Wrapped so a health-check failure can never sink
    # the pipeline it exists to monitor.
    try:
        record_and_alert_ingestion(
            run_date=datetime.now(timezone.utc).date(),
            by_source={**summary.get("free_by_source", {}), **scraped.get("scraped_by_source", {})},
            errored={**summary.get("free_errors", {}), **scraped.get("scraped_errors", {})},
        )
    except Exception:
        logger.exception("Ingestion health check failed (non-fatal)")

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
    return _strip_internal(summary)


async def run_daily_pipeline_for_profile(profile: dict) -> dict:
    """The authenticated "Run agent now" path — refreshes the shared job
    pool (the caller is waiting for fresh listings) but only processes
    their own profile, not every beta user's.
    """
    summary = await _refresh_and_backfill()
    summary.update(_process_profile(profile))
    return _strip_internal(summary)
