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
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from config import settings
from services.job_ingestion import refresh_unstop
from services.job_sources import fetch_unstop_internships


@pytest.fixture(autouse=True)
def _single_role(monkeypatch):
    # Pin to one role so pagination call-counts are deterministic; the multi-role
    # fan-out gets its own explicit test below.
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
        "approved_date": "2026-07-18T10:00:00Z",
        "details": "<p>Build <strong>React</strong> components.</p>",
        "reg_status": "STARTED",
    }
    row.update(overrides)
    return row


# --- mapping + money ---------------------------------------------------------


def test_maps_recon_fields():
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([_row()]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]

    assert job.source == "unstop"
    assert job.external_id == "123456"
    assert job.title == "Full Stack Development Internship"
    assert job.company == "Acme Corp"  # organisation.name
    assert job.location == "Bangalore"  # canonicalized from "Bengaluru"
    assert job.description == "Build React components."  # HTML stripped
    assert job.redirect_url.startswith("https://unstop.com/internships/")
    assert job.posted_at.year == 2026 and job.posted_at.month == 7  # approved_date


def test_monthly_stipend_is_annualized_as_inr():
    # 15,000/month → 180,000/yr, 25,000/month → 300,000/yr, and "fa-rupee" → INR.
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([_row()]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]

    assert job.salary_min == 180_000
    assert job.salary_max == 300_000
    assert job.salary_currency == "INR"


def test_yearly_pay_in_is_not_multiplied():
    row = _row(jobDetail={**_row()["jobDetail"], "pay_in": "yearly", "min_salary": 600000, "max_salary": 900000})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]

    assert (job.salary_min, job.salary_max) == (600_000, 900_000)


def test_unpaid_internship_has_null_salary_but_still_inr():
    row = _row(jobDetail={**_row()["jobDetail"], "paid_unpaid": "unpaid", "min_salary": None, "max_salary": None})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]

    assert (job.salary_min, job.salary_max) == (None, None)
    # India-only source → INR default, never "$" by omission.
    assert job.salary_currency == "INR"


def test_gmt_offset_date_is_parsed_not_dropped():
    # Regression for the 2026-07-21 incident: approved_date "…GMT+0530" made every
    # row fail JobIn validation and get dropped, so Unstop returned 0 jobs.
    row = _row(approved_date="2026-07-08 01:21:36 GMT+0530")
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]
    assert job.posted_at is not None
    assert job.posted_at.year == 2026 and job.posted_at.month == 7 and job.posted_at.day == 8


def test_searchterm_is_sent_per_role():
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop_internships(5))
    # target_roles is pinned to one role by the fixture → searchTerm carries it.
    params = get.await_args.kwargs["params"]
    assert params["searchTerm"] == "full stack development"
    assert params["opportunity"] == "internships"


def test_multiple_roles_each_get_their_own_search(monkeypatch):
    monkeypatch.setattr(settings, "target_roles", "fullstack developer, frontend developer, cloud architect")
    get = AsyncMock(return_value=_page([_row()], last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        asyncio.run(fetch_unstop_internships(5))
    terms = [c.kwargs["params"].get("searchTerm") for c in get.await_args_list]
    assert terms == ["fullstack developer", "frontend developer", "cloud architect"]


def test_wfh_posting_is_tagged_remote():
    # A work-from-home row has no city but IS eligible — tag it "Remote" from the
    # structured work-mode so the relevance gate's remote path keeps it.
    row = _row(locations=[], jobDetail={**_row()["jobDetail"], "type": "wfh"})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]
    assert job.location == "Remote"


def test_non_wfh_posting_with_empty_locations_stays_none():
    # No city and NOT work-from-home → location None (don't fabricate "Remote").
    row = _row(locations=[], jobDetail={**_row()["jobDetail"], "type": "in_office"})
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([row]))):
        job = asyncio.run(fetch_unstop_internships(10))[0]
    assert job.location is None


# --- pagination + cap --------------------------------------------------------


def test_caps_at_max_results_within_a_page():
    rows = [_row(id=i, title=f"Intern {i}") for i in range(5)]
    get = AsyncMock(return_value=_page(rows, last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop_internships(2))

    assert len(jobs) == 2  # sliced to the cap even though the page held 5
    assert get.await_count == 1  # one page was enough


def test_follows_pagination_until_the_cap():
    page1 = _page([_row(id=1), _row(id=2)], current_page=1, last_page=3)
    page2 = _page([_row(id=3), _row(id=4)], current_page=2, last_page=3)
    get = AsyncMock(side_effect=[page1, page2])
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop_internships(3))

    assert len(jobs) == 3
    assert get.await_count == 2  # stopped as soon as the cap was met, not at last_page=3


def test_stops_at_last_page_even_below_cap():
    # Only 2 open internships exist, but we asked for 10 — don't loop forever.
    get = AsyncMock(return_value=_page([_row(id=1), _row(id=2)], current_page=1, last_page=1))
    with patch("httpx.AsyncClient.get", new=get):
        jobs = asyncio.run(fetch_unstop_internships(10))

    assert len(jobs) == 2
    assert get.await_count == 1


def test_zero_cap_makes_no_request():
    get = AsyncMock()
    with patch("httpx.AsyncClient.get", new=get):
        assert asyncio.run(fetch_unstop_internships(0)) == []
    get.assert_not_awaited()


# --- isolation ---------------------------------------------------------------


def test_http_error_yields_what_was_collected_never_raises():
    import httpx

    get = AsyncMock(side_effect=httpx.ConnectError("down"))
    with patch("httpx.AsyncClient.get", new=get):
        assert asyncio.run(fetch_unstop_internships(10)) == []


def test_malformed_rows_are_skipped():
    junk = [{}, {"title": "No ID"}, {"id": 9}]  # missing id or title
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page(junk))):
        assert asyncio.run(fetch_unstop_internships(10)) == []


def test_unexpected_response_shape_returns_empty_not_raises():
    # The 2026-07-21 incident: from Cloud Run the endpoint 200s with a different
    # envelope (WAF/challenge), so `data` isn't the paginator dict. Must degrade
    # to [] with a logged warning, never raise (which would vanish upstream).
    for bad in ([], "blocked", None, {"data": "not-a-list"}, {"data": [1, 2, 3]}):
        resp = MagicMock()
        resp.json.return_value = {"data": bad} if not isinstance(bad, dict) else bad
        resp.raise_for_status = MagicMock()
        with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=resp)):
            assert asyncio.run(fetch_unstop_internships(10)) == []


def test_non_json_body_returns_empty():
    resp = MagicMock()
    resp.json.side_effect = ValueError("Expecting value")  # HTML challenge page
    resp.raise_for_status = MagicMock()
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=resp)):
        assert asyncio.run(fetch_unstop_internships(10)) == []


def test_row_mapping_exception_skips_row_not_page():
    # A row whose jobDetail is a list (not dict) would raise in _unstop_row_to_job;
    # it must be skipped, and a valid row on the same page must still come through.
    good = _row(id=1)
    bad = _row(id=2, jobDetail=["unexpected"])
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_page([bad, good]))):
        jobs = asyncio.run(fetch_unstop_internships(10))
    assert [j.external_id for j in jobs] == ["1"]


# --- containment: gated + cron-only ------------------------------------------


def test_refresh_unstop_is_disabled_by_default(monkeypatch):
    monkeypatch.setattr(settings, "enable_india_sources", False)
    with (
        patch("services.job_ingestion.fetch_unstop_internships") as fetch,
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
        patch("services.job_ingestion.fetch_unstop_internships", new=AsyncMock(return_value=[job])) as fetch,
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
