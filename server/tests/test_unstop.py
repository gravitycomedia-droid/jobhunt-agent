"""Unstop direct-fetch source (ADR-003 v2, plan 15 Phase D).

Unstop is the odd one out among the scraped sources: free, direct httpx (no
Apify), and salaries arrive PRE-PARSED as ints — so it never touches salary.py's
text parser. The row below is shaped from the Phase B live recon
(docs/UNSTOP_ENDPOINT.md), captured off a real call, not guessed.

Two things a reviewer should look hardest at:
  1. Money: monthly stipends must annualize, unpaid must be null, "fa-rupee"
     must become INR (never "$").
  2. Containment: Unstop is scraping under ADR-003 v2, so it must be gated by
     ENABLE_INDIA_SOURCES and reachable ONLY from the cron path.
"""

import asyncio
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from config import settings
from services.job_ingestion import refresh_unstop
from services.job_sources import fetch_unstop


@pytest.fixture(autouse=True)
def _deterministic_crawl(monkeypatch):
    # Pin the crawl to ONE opportunity type and no keyword search, so the
    # pagination call-counts below stay deterministic. The fan-out across
    # opportunity types and search terms gets its own explicit tests.
    monkeypatch.setattr(settings, "unstop_opportunity_types", "internships")
    monkeypatch.setattr(settings, "unstop_search_terms", "")
    monkeypatch.setattr(settings, "target_roles", "full stack development")


def _page(rows, current_page=1, last_page=1) -> MagicMock:
    """A Laravel-paginator response: {"data": {"data": [...], ...}}."""
    resp = MagicMock()
    resp.json.return_value = {
        "data": {"data": rows, "current_page": current_page, "last_page": last_page, "total": len(rows)}
    }
    resp.raise_for_status = MagicMock()
    return resp


def _row(**overrides) -> dict:
    row = {
        "id": 123456,
        "title": "Full Stack Development Internship",
        "organisation": {"name": "Acme Corp"},
        "seo_url": "https://unstop.com/internships/full-stack-development-acme-123456",
        "locations": [{"city": "Bengaluru"}],
        "jobDetail": {
            "type": "in_office",
            "timing": "full_time",
            "min_salary": 15000,
            "max_salary": 25000,
            "currency": "fa-rupee",
            "pay_in": "monthly",
            "paid_unpaid": "paid",
        },
        # Deliberately RELATIVE, not a hardcoded date. The crawl now stops early
        # on consecutive all-stale pages (UNSTOP_STALE_PAGE_STREAK), so a fixed
        # date would silently start truncating these fixtures' pagination once
        # real-world time drifted past max_job_age_days — a test that rots into a
        # false pass. "Yesterday" is always fresh.
        "approved_date": (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S GMT+0000"),
        "details": "<p>Build <strong>React</strong> components.</p>",
        "reg_status": "STARTED",
    }
    row.update(overrides)
    return row


# --- mapping + money ---------------------------------------------------------


def test_maps_recon_fields():
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([_row()]))):
        job = asyncio.run(fetch_unstop(10))[0]

    assert job.source == "unstop"
    assert job.external_id == "123456"
    assert job.title == "Full Stack Development Internship"
    assert job.company == "Acme Corp"  # organisation.name
    assert job.location == "Bangalore"  # canonicalized from "Bengaluru"
    assert job.description == "Build React components."  # HTML stripped
    assert job.redirect_url.startswith("https://unstop.com/internships/")
    # approved_date. Asserted as RECENCY, not a hardcoded month: the fixture
    # deliberately builds this date relative to now (see _row) so the crawl's
    # freshness early-stop doesn't truncate it as real time moves on. Pinning
    # "month == 7" defeated that and failed the moment the month turned.
    assert job.posted_at is not None
    assert (datetime.now(timezone.utc) - job.posted_at) < timedelta(days=2)


def test_monthly_stipend_is_annualized_as_inr():
    # 15,000/month → 180,000/yr, 25,000/month → 300,000/yr, and "fa-rupee" → INR.
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([_row()]))):
        job = asyncio.run(fetch_unstop(10))[0]

    assert job.salary_min == 180_000
    assert job.salary_max == 300_000
    assert job.salary_currency == "INR"


def test_missing_pay_in_defaults_to_monthly():
    # Regression: an Unstop stipend with no pay_in must annualize as monthly (x12),
    # not render ₹12,000/month as a ₹12,000/YEAR salary. All rows here are interns.
    row = _row(jobDetail={**_row()["jobDetail"], "pay_in": None, "min_salary": 12000, "max_salary": 12000})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]
    assert job.salary_min == 144_000
    assert job.salary_max == 144_000


def test_yearly_pay_in_is_not_multiplied():
    row = _row(jobDetail={**_row()["jobDetail"], "pay_in": "yearly", "min_salary": 600000, "max_salary": 900000})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]

    assert (job.salary_min, job.salary_max) == (600_000, 900_000)


def test_unpaid_internship_has_null_salary_but_still_inr():
    row = _row(jobDetail={**_row()["jobDetail"], "paid_unpaid": "unpaid", "min_salary": None, "max_salary": None})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]

    assert (job.salary_min, job.salary_max) == (None, None)
    # India-only source → INR default, never "$" by omission.
    assert job.salary_currency == "INR"


def test_gmt_offset_date_is_parsed_not_dropped():
    # Regression for the 2026-07-21 incident: approved_date "…GMT+0530" made every
    # row fail JobIn validation and get dropped, so Unstop returned 0 jobs.
    row = _row(approved_date="2026-07-08 01:21:36 GMT+0530")
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]
    assert job.posted_at is not None
    assert job.posted_at.year == 2026 and job.posted_at.month == 7 and job.posted_at.day == 8


# --- what gets crawled (ADR-003 v3) ------------------------------------------


def test_no_search_term_by_default_so_the_whole_catalogue_is_crawled():
    """The v3 behaviour change. Before, searchTerm was set from target_roles on
    every call, which capped the pool at three role keywords; the broad pool
    wants the unfiltered catalogue, so searchTerm must be ABSENT."""
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop(5))
    params = get.await_args.kwargs["params"]
    assert "searchTerm" not in params
    assert params["opportunity"] == "internships"


def test_search_terms_are_sent_when_configured(monkeypatch):
    # Keyword mode is still reachable — it's now opt-in config rather than the
    # default, so narrowing the fetch back down needs no code change.
    monkeypatch.setattr(settings, "unstop_search_terms", "fullstack developer, cloud architect")
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop(5))
    terms = [c.kwargs["params"].get("searchTerm") for c in get.await_args_list]
    assert terms == ["fullstack developer", "cloud architect"]


def test_both_opportunity_types_are_crawled(monkeypatch):
    # `jobs` carries ~1,186 open postings that the internships-only fetcher never
    # saw. Probed live 2026-07-26 — this is the other half of the volume.
    monkeypatch.setattr(settings, "unstop_opportunity_types", "internships,jobs")
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop(5))
    assert [c.kwargs["params"]["opportunity"] for c in get.await_args_list] == ["internships", "jobs"]


def test_unknown_opportunity_type_is_dropped_not_sent(monkeypatch):
    # "freshers" LOOKS like a valid type but returns total=0 from Unstop, which
    # in the health log is indistinguishable from "the source died". Drop it here
    # rather than let it masquerade as an outage.
    monkeypatch.setattr(settings, "unstop_opportunity_types", "internships,freshers")
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop(5))
    assert [c.kwargs["params"]["opportunity"] for c in get.await_args_list] == ["internships"]


def test_all_types_invalid_makes_no_request(monkeypatch):
    monkeypatch.setattr(settings, "unstop_opportunity_types", "freshers,entry-level")
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        assert asyncio.run(fetch_unstop(5)) == []
    get.assert_not_awaited()


# --- freshness early stop ----------------------------------------------------


def _stale_row(**overrides) -> dict:
    days = settings.max_job_age_days + 5
    stale = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S GMT+0000")
    return _row(approved_date=stale, **overrides)


def test_crawl_stops_after_consecutive_stale_pages():
    # Results are newest-first, so once pages go older than max_job_age_days
    # every later page is too — is_fresh() would bin them at ingestion anyway.
    # Stopping there is what turns a 21-request cold crawl into ~3/day.
    stale = _page([_stale_row(id=1), _stale_row(id=2)], current_page=1, last_page=50)
    get = AsyncMock(return_value=stale)
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop(1000))
    # Two stale pages, then stop — not all 50.
    assert get.await_count == 2


def test_a_single_stale_page_does_not_stop_the_crawl():
    # One odd page (a bumped posting, an all-undated page) must not truncate an
    # otherwise-fresh crawl — hence a STREAK, not a single trigger.
    pages = [
        _page([_stale_row(id=1)], current_page=1, last_page=3),
        _page([_row(id=2)], current_page=2, last_page=3),
        _page([_row(id=3)], current_page=3, last_page=3),
    ]
    get = AsyncMock(side_effect=pages)
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop(1000))
    assert get.await_count == 3
    assert [j.external_id for j in jobs] == ["1", "2", "3"]


def test_undated_rows_never_count_as_stale():
    # posted_at=None is "unknown", not "old" — is_fresh() passes those through,
    # so a page of them must not trigger the early stop either.
    undated = _page([_row(id=1, approved_date=None)], current_page=1, last_page=2)
    last = _page([_row(id=2)], current_page=2, last_page=2)
    get = AsyncMock(side_effect=[undated, last])
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop(1000))
    assert get.await_count == 2
    assert len(jobs) == 2


def test_wfh_posting_is_tagged_remote():
    # A work-from-home row has no city but IS eligible — tag it "Remote" from the
    # structured work-mode so the relevance gate's remote path keeps it.
    row = _row(locations=[], jobDetail={**_row()["jobDetail"], "type": "wfh"})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]
    assert job.location == "Remote"


def test_non_wfh_posting_with_empty_locations_stays_none():
    # No city and NOT work-from-home → location None (don't fabricate "Remote").
    row = _row(locations=[], jobDetail={**_row()["jobDetail"], "type": "in_office"})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop(10))[0]
    assert job.location is None


# --- pagination + cap --------------------------------------------------------


def test_caps_at_max_results_within_a_page():
    rows = [_row(id=i, title=f"Intern {i}") for i in range(5)]
    get = AsyncMock(return_value=_page(rows, last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop(2))

    assert len(jobs) == 2  # sliced to the cap even though the page held 5
    assert get.await_count == 1  # one page was enough


def test_follows_pagination_until_the_cap():
    page1 = _page([_row(id=1), _row(id=2)], current_page=1, last_page=3)
    page2 = _page([_row(id=3), _row(id=4)], current_page=2, last_page=3)
    get = AsyncMock(side_effect=[page1, page2])
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop(3))

    assert len(jobs) == 3
    assert get.await_count == 2  # stopped as soon as the cap was met, not at last_page=3


def test_stops_at_last_page_even_below_cap():
    # Only 2 open internships exist, but we asked for 10 — don't loop forever.
    get = AsyncMock(return_value=_page([_row(id=1), _row(id=2)], current_page=1, last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop(10))

    assert len(jobs) == 2
    assert get.await_count == 1


def test_zero_cap_makes_no_request():
    get = AsyncMock()
    with patch("httpx.AsyncClient.get", new=get):
        assert asyncio.run(fetch_unstop(0)) == []
    get.assert_not_awaited()


# --- isolation ---------------------------------------------------------------


def test_http_error_yields_what_was_collected_never_raises():
    import httpx

    get = AsyncMock(side_effect=httpx.ConnectError("down"))
    with patch("httpx.AsyncClient.get", new=get):
        assert asyncio.run(fetch_unstop(10)) == []


def test_malformed_rows_are_skipped():
    junk = [{}, {"title": "No ID"}, {"id": 9}]  # missing id or title
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page(junk))):
        assert asyncio.run(fetch_unstop(10)) == []


def test_unexpected_response_shape_returns_empty_not_raises():
    # The 2026-07-21 incident: from Cloud Run the endpoint 200s with a different
    # envelope (WAF/challenge), so `data` isn't the paginator dict. Must degrade
    # to [] with a logged warning, never raise (which would vanish upstream).
    for bad in ([], "blocked", None, {"data": "not-a-list"}, {"data": [1, 2, 3]}):
        resp = MagicMock()
        resp.json.return_value = {"data": bad} if not isinstance(bad, dict) else bad
        resp.raise_for_status = MagicMock()
        with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=resp)):
            assert asyncio.run(fetch_unstop(10)) == []


def test_non_json_body_returns_empty():
    resp = MagicMock()
    resp.json.side_effect = ValueError("Expecting value")  # HTML challenge page
    resp.raise_for_status = MagicMock()
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=resp)):
        assert asyncio.run(fetch_unstop(10)) == []


def test_row_mapping_exception_skips_row_not_page():
    # A row whose jobDetail is a list (not dict) would raise in _unstop_row_to_job;
    # it must be skipped, and a valid row on the same page must still come through.
    good = _row(id=1)
    bad = _row(id=2, jobDetail=["unexpected"])
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([bad, good]))):
        jobs = asyncio.run(fetch_unstop(10))
    assert [j.external_id for j in jobs] == ["1"]


# --- containment: gated + cron-only ------------------------------------------


def test_refresh_unstop_is_disabled_by_default(monkeypatch):
    monkeypatch.setattr(settings, "enable_india_sources", False)
    with (
        patch("services.job_ingestion.fetch_unstop") as fetch,
        patch("services.job_ingestion._dedup_embed_insert") as insert,
    ):
        result = asyncio.run(refresh_unstop())

    assert result["skipped"] == "disabled"
    fetch.assert_not_called()  # not even a single request when the flag is off
    insert.assert_not_called()


def test_refresh_unstop_runs_when_enabled(monkeypatch):
    from models.job import JobIn

    monkeypatch.setattr(settings, "enable_india_sources", True)
    monkeypatch.setattr(settings, "unstop_max_results", 20)
    job = JobIn(source="unstop", external_id="1", title="Intern", company="Acme", location="Bangalore")
    with (
        patch("services.job_ingestion.fetch_unstop", new=AsyncMock(return_value=[job])) as fetch,
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 1, "inserted": 1}),
    ):
        result = asyncio.run(refresh_unstop())

    fetch.assert_awaited_once_with(20)  # capped by the setting
    assert result["by_source"] == {"unstop": 1}


def test_run_agent_now_never_touches_unstop():
    """The per-user "Run agent now" path must not reach Unstop — same containment
    as the paid Apify sources. Unstop lives in _refresh_scraped_if_due (cron), not
    the shared _refresh_and_backfill()."""
    import jobs.daily_pipeline as pipeline

    with (
        patch.object(pipeline, "refresh_job_pool", new=AsyncMock(return_value={"fetched": 0, "inserted": 0})),
        patch.object(pipeline, "backfill_job_embeddings", return_value={"backfilled": 0}),
        patch.object(pipeline, "refresh_unstop", new=AsyncMock()) as unstop,
        patch.object(pipeline, "rerank_shortlist", return_value={"reranked": 0}),
        patch.object(pipeline, "_draft_pending_followups", return_value=0),
        patch.object(pipeline, "send_push_notification", MagicMock()),
    ):
        asyncio.run(pipeline.run_daily_pipeline_for_profile({"id": "p1", "notification_prefs": {}}))

    unstop.assert_not_called()
