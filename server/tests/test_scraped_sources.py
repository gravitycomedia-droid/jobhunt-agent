"""refresh_scraped_sources() + the cadence gate.

These sources cost real money per result, so the tests that matter most here are
the ones asserting we DON'T call them: wrong weekday, no token, no actor ID, and
— the one a reviewer should look hardest at — that the user-facing "Run agent
now" path can't trigger paid scraping at all.
"""

import asyncio
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from config import settings
from services.job_ingestion import refresh_scraped_sources, should_scrape_today


MON = datetime(2026, 7, 13, tzinfo=timezone.utc)
TUE = datetime(2026, 7, 14, tzinfo=timezone.utc)
WED = datetime(2026, 7, 15, tzinfo=timezone.utc)
THU = datetime(2026, 7, 16, tzinfo=timezone.utc)
SUN = datetime(2026, 7, 19, tzinfo=timezone.utc)


@pytest.fixture(autouse=True)
def _configured(monkeypatch):
    monkeypatch.setattr(settings, "apify_api_token", "test-token")
    monkeypatch.setattr(settings, "apify_linkedin_actor_id", "owner~linkedin")
    monkeypatch.setattr(settings, "apify_indeed_actor_id", "owner~indeed")
    monkeypatch.setattr(settings, "apify_naukri_actor_id", "owner~naukri")
    # Cheap source runs often, priciest runs weekly.
    monkeypatch.setattr(settings, "apify_linkedin_weekdays", "mon,wed,fri")
    monkeypatch.setattr(settings, "apify_indeed_weekdays", "mon,thu")
    monkeypatch.setattr(settings, "apify_naukri_weekdays", "mon")
    monkeypatch.setattr(settings, "apify_linkedin_max_results", 10)
    monkeypatch.setattr(settings, "apify_indeed_max_results", 5)
    monkeypatch.setattr(settings, "apify_naukri_max_results", 8)
    monkeypatch.setattr(settings, "apify_max_concurrent_runs", 3)
    monkeypatch.setattr(settings, "target_roles", "fullstack developer,frontend developer")
    monkeypatch.setattr(settings, "target_locations", "hyderabad,bangalore,remote")


# --- per-source cadence ------------------------------------------------------


@pytest.mark.parametrize(
    "day,expected",
    [
        (MON, {"linkedin", "indeed", "naukri"}),  # everything lands on Monday
        (TUE, set()),  # nothing scheduled
        (WED, {"linkedin"}),  # only the cheap source
        (THU, {"indeed"}),  # LinkedIn is mon/wed/fri; Naukri (priciest) is weekly
        (SUN, set()),
    ],
)
def test_each_source_runs_on_its_own_cadence(day, expected):
    from services.job_ingestion import _scraped_sources_due

    assert {name for name, _, _ in _scraped_sources_due(day)} == expected


def test_naukri_runs_only_once_a_week():
    from services.job_ingestion import _scraped_sources_due

    days = [datetime(2026, 7, 13 + i, tzinfo=timezone.utc) for i in range(7)]  # Mon..Sun
    naukri_days = [d for d in days if "naukri" in {n for n, _, _ in _scraped_sources_due(d)}]
    assert len(naukri_days) == 1


def test_internshala_is_gated_by_the_master_switch(monkeypatch):
    """ADR-003 v2 sign-off gate, in code: Internshala must NOT enter the rotation
    while ENABLE_INDIA_SOURCES is false, even with its actor ID set and today on
    its cadence. Config alone can't take a new scraped source live."""
    from services.job_ingestion import _scraped_sources_due

    monkeypatch.setattr(settings, "apify_internshala_actor_id", "owner~internshala")
    monkeypatch.setattr(settings, "apify_internshala_weekdays", "tue,fri")
    monkeypatch.setattr(settings, "internshala_max_results", 10)

    # Switch OFF → absent from the rotation on TUE (one of its weekdays).
    monkeypatch.setattr(settings, "enable_india_sources", False)
    assert "internshala" not in {n for n, _, _ in _scraped_sources_due(TUE)}

    # Switch ON → runs on its own cadence, and stays off on a non-cadence day.
    monkeypatch.setattr(settings, "enable_india_sources", True)
    assert "internshala" in {n for n, _, _ in _scraped_sources_due(TUE)}
    assert "internshala" not in {n for n, _, _ in _scraped_sources_due(WED)}


def test_should_scrape_today_is_true_only_when_something_is_due():
    assert should_scrape_today(MON) is True
    assert should_scrape_today(WED) is True  # LinkedIn alone
    assert should_scrape_today(TUE) is False


def test_blank_weekdays_is_a_per_source_kill_switch(monkeypatch):
    from services.job_ingestion import _scraped_sources_due

    monkeypatch.setattr(settings, "apify_naukri_weekdays", "")
    assert "naukri" not in {n for n, _, _ in _scraped_sources_due(MON)}
    # ...and the other sources are unaffected.
    assert "linkedin" in {n for n, _, _ in _scraped_sources_due(MON)}


# --- spend guards ------------------------------------------------------------


def test_no_token_is_a_noop(monkeypatch):
    monkeypatch.setattr(settings, "apify_api_token", "")
    with patch("services.job_ingestion._dedup_embed_insert") as insert:
        result = asyncio.run(refresh_scraped_sources())
    assert result["calls"] == 0
    assert result["skipped"] == "no_token"
    insert.assert_not_called()  # nothing fetched → don't even touch the DB


def test_no_actor_ids_is_a_noop(monkeypatch):
    for field in ("apify_linkedin_actor_id", "apify_indeed_actor_id", "apify_naukri_actor_id"):
        monkeypatch.setattr(settings, field, "")
    result = asyncio.run(refresh_scraped_sources(MON))
    assert result["calls"] == 0
    assert result["skipped"] == "not_due"


def test_off_cadence_source_is_never_called():
    # Wednesday: only LinkedIn is due. Naukri is the priciest source per job, so
    # calling it off-cadence is a direct, unbudgeted cost.
    with (
        patch("services.job_ingestion.fetch_linkedin_apify", new=AsyncMock(return_value=[])) as li,
        patch("services.job_ingestion.fetch_indeed_apify", new=AsyncMock(return_value=[])) as indeed,
        patch("services.job_ingestion.fetch_naukri_apify", new=AsyncMock(return_value=[])) as naukri,
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}),
    ):
        asyncio.run(refresh_scraped_sources(WED))

    assert li.call_count == 6
    indeed.assert_not_called()
    naukri.assert_not_called()


def test_each_source_gets_its_own_cap():
    # An unbounded fetch is an unbounded bill, and the caps differ per source
    # because the per-job prices differ ~10x.
    with (
        patch("services.job_ingestion.fetch_linkedin_apify", new=AsyncMock(return_value=[])) as li,
        patch("services.job_ingestion.fetch_indeed_apify", new=AsyncMock(return_value=[])) as indeed,
        patch("services.job_ingestion.fetch_naukri_apify", new=AsyncMock(return_value=[])) as naukri,
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}),
    ):
        result = asyncio.run(refresh_scraped_sources(MON))

    assert result["calls"] == 18  # 2 roles x 3 locations x 3 sources due Monday
    assert all(c.args[2] == 10 for c in li.call_args_list)
    assert all(c.args[2] == 5 for c in indeed.call_args_list)
    assert all(c.args[2] == 8 for c in naukri.call_args_list)


def test_concurrency_is_bounded(monkeypatch):
    """Apify's free plan allows 16GB of actor memory in flight and each run
    reserves ~4GB. An unbounded gather() asks for ~48GB, and Apify rejects the
    overflow with a 402 that reads like "out of credit" but isn't — this is the
    bug that made a live run lose 6 of 6 LinkedIn calls."""
    monkeypatch.setattr(settings, "apify_max_concurrent_runs", 3)

    in_flight = 0
    peak = 0

    async def slow_fetch(role, location, cap):
        nonlocal in_flight, peak
        in_flight += 1
        peak = max(peak, in_flight)
        await asyncio.sleep(0.01)
        in_flight -= 1
        return []

    with (
        patch("services.job_ingestion.fetch_linkedin_apify", new=slow_fetch),
        patch("services.job_ingestion.fetch_indeed_apify", new=slow_fetch),
        patch("services.job_ingestion.fetch_naukri_apify", new=slow_fetch),
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}),
    ):
        asyncio.run(refresh_scraped_sources(MON))

    assert peak <= 3, f"{peak} runs in flight at once — the free plan 402s past ~4"


def test_one_source_raising_does_not_lose_the_other():
    from models.job import JobIn

    good = JobIn(source="naukri", external_id="1", title="Dev", company="Acme", location="Hyderabad")
    with (
        patch("services.job_ingestion.fetch_linkedin_apify", new=AsyncMock(side_effect=RuntimeError("actor blew up"))),
        patch("services.job_ingestion.fetch_indeed_apify", new=AsyncMock(return_value=[])),
        patch("services.job_ingestion.fetch_naukri_apify", new=AsyncMock(return_value=[good])),
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 6, "inserted": 6}) as insert,
    ):
        result = asyncio.run(refresh_scraped_sources(MON))

    # LinkedIn's 6 calls all raised; Naukri's 6 jobs still made it through.
    assert result["inserted"] == 6
    assert len(insert.call_args[0][0]) == 6


# --- the important one: paid scraping must not be user-triggerable ------------


def test_manual_refresh_never_scrapes():
    """POST /jobs/refresh → refresh_job_pool() must touch only the free sources.
    If this ever fails, a user mashing the refresh button spends your money."""
    import services.job_ingestion as ingestion

    with (
        patch.object(ingestion, "fetch_adzuna", new=AsyncMock(return_value=[])),
        patch.object(ingestion, "fetch_jsearch", new=AsyncMock(return_value=[])),
        patch.object(ingestion, "fetch_greenhouse", new=AsyncMock(return_value=[])),
        patch.object(ingestion, "fetch_lever", new=AsyncMock(return_value=[])),
        patch.object(ingestion, "fetch_linkedin_apify", new=AsyncMock(return_value=[])) as li,
        patch.object(ingestion, "fetch_indeed_apify", new=AsyncMock(return_value=[])) as indeed,
        patch.object(ingestion, "fetch_naukri_apify", new=AsyncMock(return_value=[])) as naukri,
        patch.object(ingestion, "_dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}),
    ):
        asyncio.run(ingestion.refresh_job_pool())

    li.assert_not_called()
    indeed.assert_not_called()
    naukri.assert_not_called()


def test_run_agent_now_never_scrapes():
    """The app's "Run agent now" button (run_daily_pipeline_for_profile) shares
    _refresh_and_backfill() with the cron. Scraping must live OUTSIDE that shared
    helper, or the button becomes a spend button."""
    import jobs.daily_pipeline as pipeline

    with (
        patch.object(pipeline, "refresh_job_pool", new=AsyncMock(return_value={"fetched": 0, "inserted": 0})),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "refresh_scraped_sources", new=AsyncMock()) as scrape,
        patch.object(pipeline, "rerank_shortlist", return_value={"reranked": 0}),
        patch.object(pipeline, "_draft_pending_followups", return_value=0),
        patch.object(pipeline, "send_push_notification", MagicMock()),
    ):
        asyncio.run(pipeline.run_daily_pipeline_for_profile({"id": "p1", "notification_prefs": {}}))

    scrape.assert_not_called()


def test_cron_scrapes_only_on_scheduled_days():
    import jobs.daily_pipeline as pipeline

    with (
        patch.object(pipeline, "refresh_job_pool", new=AsyncMock(return_value={"fetched": 0, "inserted": 0})),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "should_scrape_today", return_value=False),
        patch.object(pipeline, "refresh_scraped_sources", new=AsyncMock()) as scrape,
        patch.object(pipeline.supabase, "table") as table,
    ):
        table.return_value.select.return_value.execute.return_value = MagicMock(data=[])
        asyncio.run(pipeline.run_daily_pipeline_for_all())

    scrape.assert_not_called()


def test_scraping_failure_does_not_crash_the_pipeline():
    """The plan's acceptance criterion: a bad Apify token (or any systemic
    scrape failure) logs and lets re-ranks/follow-ups still run."""
    import jobs.daily_pipeline as pipeline

    with (
        patch.object(pipeline, "refresh_job_pool", new=AsyncMock(return_value={"fetched": 5, "inserted": 5})),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "should_scrape_today", return_value=True),
        patch.object(pipeline, "refresh_scraped_sources", new=AsyncMock(side_effect=RuntimeError("401"))),
        patch.object(pipeline.supabase, "table") as table,
    ):
        table.return_value.select.return_value.execute.return_value = MagicMock(data=[])
        summary = asyncio.run(pipeline.run_daily_pipeline_for_all())

    # The free sources' work survived the scrape blowing up.
    assert summary["jobs_inserted"] == 5
    assert summary["scraped_inserted"] == 0
