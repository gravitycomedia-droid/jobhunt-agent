"""Ingestion health check + ops alert (plan 15, Phase F).

Two layers under test:
  - evaluate_ingestion_health(): the pure decision logic — zero/error/low
    detection against a trailing average, no DB, no clock.
  - record_and_alert_ingestion(): the I/O shell — that it writes the log rows,
    reads the trailing window, and only emails when something is actually wrong.

The three acceptance criteria from the plan map to
test_zero_result_run_fires_alert, test_normal_run_stays_silent, and
test_fetch_exception_is_logged_and_alerted.
"""

from datetime import date
from unittest.mock import MagicMock, patch

from services.ingestion_health import (
    ANOMALY_FRACTION,
    evaluate_ingestion_health,
    record_and_alert_ingestion,
)

RUN_DATE = date(2026, 7, 20)


def _ok(source, count):
    return {"source": source, "item_count": count, "status": "ok", "error_message": None}


def _err(source, message):
    return {"source": source, "item_count": 0, "status": "error", "error_message": message}


# --- pure evaluator ----------------------------------------------------------


def test_healthy_sources_produce_no_flags():
    today = [_ok("adzuna", 40), _ok("linkedin", 10)]
    avgs = {"adzuna": 45.0, "linkedin": 11.0}
    assert evaluate_ingestion_health(today, avgs) == []


def test_zero_count_is_flagged_even_with_no_history():
    # A brand-new source with no baseline can still be "went dark".
    flags = evaluate_ingestion_health([_ok("internshala", 0)], {})
    assert len(flags) == 1
    assert flags[0].source == "internshala"
    assert "0 items" in flags[0].reason


def test_error_status_is_always_flagged():
    # Even at count 0 with no history, a raised fetch is a problem, and its
    # reason should carry the error message, not the generic "returned 0".
    flags = evaluate_ingestion_health([_err("naukri", "TimeoutException: boom")], {})
    assert len(flags) == 1
    assert "fetch failed" in flags[0].reason
    assert "boom" in flags[0].reason


def test_anomalous_drop_against_trailing_average_is_flagged():
    # 5 against a 50 average is 10% of normal — well under the 20% floor.
    flags = evaluate_ingestion_health([_ok("indeed", 5)], {"indeed": 50.0})
    assert len(flags) == 1
    assert "indeed" == flags[0].source
    assert "avg" in flags[0].reason


def test_count_just_above_the_floor_is_not_flagged():
    # 11 vs a 50 average = 22%, just over the 20% floor → healthy.
    assert evaluate_ingestion_health([_ok("indeed", 11)], {"indeed": 50.0}) == []
    # And exactly at the boundary is NOT below it (strict <).
    at_floor = int(ANOMALY_FRACTION * 50)  # 10
    assert evaluate_ingestion_health([_ok("indeed", at_floor)], {"indeed": 50.0}) == []


def test_low_count_with_no_baseline_is_not_flagged_low():
    # A positive count with no history can't be "low" — only "zero" fires
    # without a baseline, so a new source's first non-zero day stays silent.
    assert evaluate_ingestion_health([_ok("unstop", 3)], {}) == []


# --- I/O shell ---------------------------------------------------------------


def _patch_supabase(trailing_rows):
    """Mock supabase so insert() is a no-op and the trailing-average read returns
    `trailing_rows`. Returns the table mock for call assertions."""
    table = MagicMock()
    # insert(...).execute()
    table.insert.return_value.execute.return_value = MagicMock(data=[])
    # select(...).in_(...).gte(...).lt(...).execute().data
    read_chain = table.select.return_value.in_.return_value.gte.return_value.lt.return_value
    read_chain.execute.return_value = MagicMock(data=trailing_rows)
    return table


def test_zero_result_run_fires_alert():
    table = _patch_supabase(trailing_rows=[])
    with (
        patch("services.ingestion_health.supabase.table", return_value=table),
        patch("services.ingestion_health.send_ops_alert") as alert,
    ):
        flags = record_and_alert_ingestion(RUN_DATE, by_source={"adzuna": 30, "linkedin": 0})

    assert {f.source for f in flags} == {"linkedin"}
    alert.assert_called_once()
    subject, body = alert.call_args[0]
    assert "linkedin" in body


def test_normal_run_stays_silent():
    trailing = [
        {"source": "adzuna", "item_count": 40, "status": "ok"},
        {"source": "adzuna", "item_count": 50, "status": "ok"},
        {"source": "linkedin", "item_count": 10, "status": "ok"},
    ]
    table = _patch_supabase(trailing)
    with (
        patch("services.ingestion_health.supabase.table", return_value=table),
        patch("services.ingestion_health.send_ops_alert") as alert,
    ):
        flags = record_and_alert_ingestion(RUN_DATE, by_source={"adzuna": 45, "linkedin": 10})

    assert flags == []
    alert.assert_not_called()


def test_fetch_exception_is_logged_and_alerted():
    # A source that RAISED is logged with status='error' and alerted regardless
    # of its (zero) count — the "logs immediately regardless of count" criterion.
    table = _patch_supabase(trailing_rows=[])
    with (
        patch("services.ingestion_health.supabase.table", return_value=table),
        patch("services.ingestion_health.send_ops_alert") as alert,
    ):
        flags = record_and_alert_ingestion(
            RUN_DATE,
            by_source={"adzuna": 30},
            errored={"naukri": "RuntimeError: actor blew up"},
        )

    # The inserted payload must carry an 'error' row for naukri.
    inserted = table.insert.call_args[0][0]
    naukri_rows = [r for r in inserted if r["source"] == "naukri"]
    assert naukri_rows and naukri_rows[0]["status"] == "error"
    assert {f.source for f in flags} == {"naukri"}
    alert.assert_called_once()


def test_errored_source_overrides_its_count_row():
    # If a source appears in BOTH by_source and errored, only the error row is
    # written — never two rows for one source in one run.
    table = _patch_supabase(trailing_rows=[])
    with (
        patch("services.ingestion_health.supabase.table", return_value=table),
        patch("services.ingestion_health.send_ops_alert"),
    ):
        record_and_alert_ingestion(RUN_DATE, by_source={"naukri": 3}, errored={"naukri": "boom"})

    inserted = table.insert.call_args[0][0]
    naukri_rows = [r for r in inserted if r["source"] == "naukri"]
    assert len(naukri_rows) == 1
    assert naukri_rows[0]["status"] == "error"


def test_nothing_to_log_is_a_noop():
    with (
        patch("services.ingestion_health.supabase.table") as table,
        patch("services.ingestion_health.send_ops_alert") as alert,
    ):
        flags = record_and_alert_ingestion(RUN_DATE, by_source={}, errored={})

    assert flags == []
    table.assert_not_called()
    alert.assert_not_called()


# --- pipeline wiring: cron logs health, the user path must not ---------------


def test_cron_records_ingestion_health():
    """run_daily_pipeline_for_all merges free + scraped per-source counts and
    hands them to the health check exactly once."""
    import asyncio

    import jobs.daily_pipeline as pipeline

    free = {"fetched": 5, "inserted": 5, "by_source": {"adzuna": 5}, "errors": {}}
    with (
        patch.object(pipeline, "refresh_job_pool", new=_AsyncReturn(free)),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "should_scrape_today", return_value=True),
        patch.object(
            pipeline,
            "refresh_scraped_sources",
            new=_AsyncReturn({"fetched": 0, "inserted": 0, "by_source": {"linkedin": 0}, "errors": {}}),
        ),
        patch.object(pipeline, "record_and_alert_ingestion") as health,
        patch.object(pipeline.supabase, "table") as table,
    ):
        table.return_value.select.return_value.execute.return_value = MagicMock(data=[])
        summary = asyncio.run(pipeline.run_daily_pipeline_for_all())

    health.assert_called_once()
    by_source = health.call_args.kwargs["by_source"]
    assert by_source == {"adzuna": 5, "linkedin": 0}
    # Internal per-source keys must not leak into the returned summary.
    assert "free_by_source" not in summary
    assert "scraped_by_source" not in summary


def test_run_agent_now_does_not_record_health():
    """The per-user path shares _refresh_and_backfill() but must NOT log health —
    that would spam ops and pollute the daily baseline with intra-day runs."""
    import asyncio

    import jobs.daily_pipeline as pipeline

    free = {"fetched": 1, "inserted": 1, "by_source": {"adzuna": 1}, "errors": {}}
    with (
        patch.object(pipeline, "refresh_job_pool", new=_AsyncReturn(free)),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "record_and_alert_ingestion") as health,
        patch.object(pipeline, "rerank_shortlist", return_value={"reranked": 0}),
        patch.object(pipeline, "_draft_pending_followups", return_value=0),
        patch.object(pipeline, "send_push_notification", MagicMock()),
    ):
        summary = asyncio.run(pipeline.run_daily_pipeline_for_profile({"id": "p1", "notification_prefs": {}}))

    health.assert_not_called()
    assert "free_by_source" not in summary


class _AsyncReturn:
    """Minimal awaitable stand-in — patch.object with new= needs a coroutine
    function, and a lambda can't be async inline in the with-block above."""

    def __init__(self, value):
        self.value = value

    async def __call__(self, *args, **kwargs):
        return self.value


def test_error_rows_are_excluded_from_the_trailing_baseline():
    # An 'error' day (count 0) must not drag the average down — otherwise one
    # outage would mask the next by lowering the bar. Trailing = [error(0),
    # ok(50)] should average to 50, so today's 8 (16%) still trips.
    trailing = [
        {"source": "indeed", "item_count": 0, "status": "error"},
        {"source": "indeed", "item_count": 50, "status": "ok"},
    ]
    table = _patch_supabase(trailing)
    with (
        patch("services.ingestion_health.supabase.table", return_value=table),
        patch("services.ingestion_health.send_ops_alert") as alert,
    ):
        flags = record_and_alert_ingestion(RUN_DATE, by_source={"indeed": 8})

    assert {f.source for f in flags} == {"indeed"}
    alert.assert_called_once()
