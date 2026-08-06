"""Global remote boards: We Work Remotely + Remotive (ADR-003 v5).

Both fixtures are LIVE captures from 2026-08-06, trimmed for size — the WWR one
is real RSS off the category feeds, the Remotive one is real API output. Nothing
here is a guessed payload shape, which is the mistake the Internshala actor's
mapping made.

What a reviewer should look hardest at:
  1. Date parsing. Both feeds use formats pydantic cannot read on its own — RFC
     2822 for RSS, naive (offset-less) ISO for Remotive. Getting this wrong is
     silent: every row fails JobIn validation and the source reports zero, which
     is exactly the 2026-07-21 Unstop incident.
  2. Geo eligibility. Most of Remotive's feed is country-locked to places a
     candidate in India cannot work.
  3. Containment. These must be cron-only and off by default, and they must NOT
     be retired on absence — an RSS feed is a rolling window, not a catalogue.
"""

import asyncio
from datetime import timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from config import settings
from services.job_ingestion import refresh_global_remote
from services.job_sources import (
    _remotive_row_to_job,
    _wwr_split_title,
    fetch_remotive,
    fetch_weworkremotely,
    is_geo_eligible,
    parse_wwr_rss,
)

FIXTURES = Path(__file__).parent / "fixtures"
WWR_XML = (FIXTURES / "wwr_feed.xml").read_text()


@pytest.fixture(autouse=True)
def _one_feed(monkeypatch):
    """Pin WWR to a single category so call-counts below stay deterministic."""
    monkeypatch.setattr(settings, "wwr_categories", "remote-programming-jobs")
    monkeypatch.setattr(settings, "global_remote_require_geo_eligible", True)


# --- WWR title splitting ------------------------------------------------------


def test_wwr_title_splits_company_from_role():
    assert _wwr_split_title("Webflow: Customer Success Manager") == (
        "Webflow",
        "Customer Success Manager",
    )


def test_wwr_title_splits_on_first_colon_only():
    """Role titles contain colons of their own — everything after the first one
    is the role, not a third field."""
    company, title = _wwr_split_title("Acme: Engineer II: Platform")
    assert company == "Acme"
    assert title == "Engineer II: Platform"


def test_wwr_title_without_colon_is_all_role():
    """No colon means no company stated. Guessing one from the first word would
    put "Senior" in the company column."""
    assert _wwr_split_title("Senior Backend Engineer") == (None, "Senior Backend Engineer")


def test_wwr_title_empty_is_not_a_crash():
    assert _wwr_split_title(None) == (None, None)
    assert _wwr_split_title("   ") == (None, None)


# --- WWR feed parsing ---------------------------------------------------------


def test_wwr_parses_live_fixture():
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    assert len(jobs) == 4
    assert {j.source for j in jobs} == {"weworkremotely"}
    # Every row must carry a company, a title and a link — the three fields the
    # job card cannot render without.
    for j in jobs:
        assert j.title and j.company and j.redirect_url
        assert j.external_id


def test_wwr_rfc2822_dates_parse():
    """RSS dates are "Thu, 06 Aug 2026 07:30:50 +0000". If this regresses every
    row silently fails JobIn validation and the source reports zero."""
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    dated = [j for j in jobs if j.posted_at]
    assert dated, "no row parsed a pubDate — the RFC 2822 reader is broken"
    for j in dated:
        assert j.posted_at.tzinfo is not None, "naive datetime would crash the freshness compare"


def test_wwr_carries_a_real_expiry_date():
    """WWR publishes per-listing expires_at, like Unstop and unlike every other
    source here. That's what lets these rows retire on a stated date rather than
    the job_expiry_days age guess."""
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    with_expiry = [j for j in jobs if j.expires_at]
    assert with_expiry, "expires_at was dropped — rows will fall back to the age rule"
    for j in with_expiry:
        assert j.expires_at.tzinfo is not None


def test_wwr_location_is_remote_not_the_region_string():
    """The feed says "Anywhere in the World", which job_filter's remote pattern
    does NOT match. Every WWR listing is remote by construction, so we state it
    — otherwise the location gate rejects the whole source."""
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    assert {j.location for j in jobs} == {"Remote"}


def test_wwr_location_passes_the_relevance_gate():
    """The point of the line above, asserted end-to-end against the real gate."""
    from services.job_filter import in_target_location

    for job in parse_wwr_rss(WWR_XML, require_geo_eligible=False):
        assert in_target_location(job.location, job.title, job.description)


def test_wwr_external_id_is_the_slug_not_the_url():
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    for j in jobs:
        assert "://" not in j.external_id
        assert j.external_id in j.redirect_url


def test_wwr_description_is_stripped_of_html():
    jobs = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    bodies = [j.description for j in jobs if j.description]
    assert bodies
    for body in bodies:
        assert "<p>" not in body and "<strong>" not in body


def test_wwr_states_no_salary_rather_than_inventing_one():
    """The feed carries no salary field. Parsing numbers out of JD prose is
    where invented figures come from."""
    for j in parse_wwr_rss(WWR_XML, require_geo_eligible=False):
        assert j.salary_min is None and j.salary_max is None


def test_wwr_malformed_xml_returns_empty_not_raises():
    assert parse_wwr_rss("<rss><channel><item>truncated") == []
    assert parse_wwr_rss("") == []


# --- geo eligibility ----------------------------------------------------------


@pytest.mark.parametrize(
    "region",
    [
        "Anywhere in the World",
        "Worldwide",
        "India",
        "Americas, Europe, Asia, Africa, Oceania",
        "Remote",
        "GLOBAL",
    ],
)
def test_geo_eligible_admits_locations_open_to_india(region):
    assert is_geo_eligible(region)


@pytest.mark.parametrize(
    "region",
    [
        "USA",
        "Brazil",
        "Uruguay",
        "Canada",
        "USA, CST (UTC-6)",
        "Europe, UK, Germany, France, European timezones",
        "Massachusetts",
    ],
)
def test_geo_eligible_rejects_country_locks(region):
    """These are all real values off the live feeds. A candidate in Hyderabad
    cannot take any of them, and storing one costs an embedding plus a re-rank
    slot to show a job they can't apply for."""
    assert not is_geo_eligible(region)


def test_geo_eligible_treats_missing_as_open():
    """A board that didn't state a restriction hasn't imposed one — unlike an
    unrecognized value, which is overwhelmingly a country name."""
    assert is_geo_eligible(None)
    assert is_geo_eligible("")
    assert is_geo_eligible("   ")


def test_wwr_geo_filter_drops_the_country_locked_row():
    """The fixture holds one Colorado-locked posting among three open ones."""
    everything = parse_wwr_rss(WWR_XML, require_geo_eligible=False)
    filtered = parse_wwr_rss(WWR_XML, require_geo_eligible=True)
    assert len(filtered) == len(everything) - 1


# --- Remotive mapping ---------------------------------------------------------


def test_remotive_naive_iso_date_gets_a_timezone():
    """publication_date is "2026-08-02T20:00:46" — no offset. A naive datetime
    reaching is_fresh() raises on the subtraction against an aware `now`."""
    job = _remotive_row_to_job(
        {"id": 1, "title": "Engineer", "publication_date": "2026-08-02T20:00:46"}
    )
    assert job.posted_at.tzinfo == timezone.utc


def test_remotive_unparseable_date_is_none_not_a_crash():
    job = _remotive_row_to_job({"id": 1, "title": "Engineer", "publication_date": "last tuesday"})
    assert job.posted_at is None


def test_remotive_parses_salary_text():
    job = _remotive_row_to_job({"id": 1, "title": "Engineer", "salary": "$20k -$35k"})
    assert job.salary_min == 20000
    assert job.salary_max == 35000


def test_remotive_unreadable_salary_is_null_not_guessed():
    job = _remotive_row_to_job({"id": 1, "title": "Engineer", "salary": "competitive"})
    assert job.salary_min is None and job.salary_max is None


def test_remotive_defaults_to_usd_but_respects_india():
    """These boards quote USD. An India-located posting must not read as USD."""
    usd = _remotive_row_to_job(
        {"id": 1, "title": "Engineer", "candidate_required_location": "Worldwide"}
    )
    assert usd.salary_currency == "USD"
    inr = _remotive_row_to_job(
        {"id": 2, "title": "Engineer", "candidate_required_location": "India"}
    )
    assert inr.salary_currency == "INR"


def test_remotive_row_without_id_or_title_is_dropped():
    assert _remotive_row_to_job({"title": "No id"}) is None
    assert _remotive_row_to_job({"id": 7}) is None


def test_remotive_links_back_to_remotive_not_the_employer():
    """Their API terms require the link back point at the Remotive posting."""
    job = _remotive_row_to_job(
        {"id": 1, "title": "Engineer", "url": "https://remotive.com/remote-jobs/x-1"}
    )
    assert job.redirect_url.startswith("https://remotive.com/")


def test_remotive_trims_company_whitespace():
    """Real values carry it ("Coalition Technologies ") and it would fork the
    dedup key against the same company from another board."""
    job = _remotive_row_to_job({"id": 1, "title": "Engineer", "company_name": "Coalition Tech "})
    assert job.company == "Coalition Tech"


def test_remotive_location_is_remote():
    job = _remotive_row_to_job(
        {"id": 1, "title": "Engineer", "candidate_required_location": "Worldwide"}
    )
    assert job.location == "Remote"


# --- fetchers -----------------------------------------------------------------


def _response(*, text=None, json_body=None) -> MagicMock:
    resp = MagicMock()
    resp.text = text
    # A real bytes body, not a MagicMock: fetch_weworkremotely() takes len() of
    # it for the size guard, and len(MagicMock()) raises.
    resp.content = (text or "").encode()
    resp.json.return_value = json_body
    resp.raise_for_status = MagicMock()
    return resp


def _client_returning(resp) -> MagicMock:
    client = MagicMock()
    client.get = AsyncMock(return_value=resp)
    ctx = MagicMock()
    ctx.__aenter__ = AsyncMock(return_value=client)
    ctx.__aexit__ = AsyncMock(return_value=False)
    return ctx, client


def test_fetch_wwr_dedups_across_category_feeds(monkeypatch):
    """The same posting is tagged both full-stack and back-end, so it appears in
    several feeds. Counting it once keeps the health log honest."""
    monkeypatch.setattr(settings, "wwr_categories", "cat-a,cat-b,cat-c")
    ctx, client = _client_returning(_response(text=WWR_XML))
    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        jobs = asyncio.run(fetch_weworkremotely())

    assert client.get.await_count == 3, "should have hit all three feeds"
    ids = [j.external_id for j in jobs]
    assert len(ids) == len(set(ids)), "same posting counted twice across feeds"
    assert len(jobs) == 3  # 4 in the fixture, 1 dropped as country-locked


def test_fetch_wwr_refuses_an_oversized_feed(monkeypatch):
    """Bounds a billion-laughs body from a compromised feed before it reaches the
    XML parser. ElementTree blocks external entities but not internal expansion."""
    from services.job_sources import WWR_MAX_FEED_BYTES

    monkeypatch.setattr(settings, "wwr_categories", "huge")
    resp = _response(text=WWR_XML)
    resp.content = b"x" * (WWR_MAX_FEED_BYTES + 1)
    ctx, _ = _client_returning(resp)
    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        assert asyncio.run(fetch_weworkremotely()) == []


def test_fetch_wwr_one_dead_feed_does_not_lose_the_others(monkeypatch):
    monkeypatch.setattr(settings, "wwr_categories", "good,bad")
    ctx = MagicMock()
    client = MagicMock()
    client.get = AsyncMock(side_effect=[_response(text=WWR_XML), RuntimeError("502")])
    ctx.__aenter__ = AsyncMock(return_value=client)
    ctx.__aexit__ = AsyncMock(return_value=False)

    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        jobs = asyncio.run(fetch_weworkremotely())

    assert jobs, "a failing second feed wiped the first feed's jobs"


def test_fetch_remotive_makes_exactly_one_call():
    """Their legal notice asks for max ~4 calls/day. The whole public feed is 31
    rows, so per-category calls would add requests without adding rows."""
    import json

    body = json.loads((FIXTURES / "remotive_jobs.json").read_text())
    ctx, client = _client_returning(_response(json_body=body))
    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        asyncio.run(fetch_remotive())
    assert client.get.await_count == 1


def test_fetch_remotive_applies_the_geo_filter():
    import json

    body = json.loads((FIXTURES / "remotive_jobs.json").read_text())
    ctx, _ = _client_returning(_response(json_body=body))
    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        jobs = asyncio.run(fetch_remotive())
    # The fixture holds one USA-locked row among four.
    assert len(jobs) == len(body["jobs"]) - 1


def test_fetch_remotive_http_failure_returns_empty_not_raises():
    ctx = MagicMock()
    client = MagicMock()
    client.get = AsyncMock(side_effect=RuntimeError("connection reset"))
    ctx.__aenter__ = AsyncMock(return_value=client)
    ctx.__aexit__ = AsyncMock(return_value=False)
    with patch("services.job_sources.httpx.AsyncClient", return_value=ctx):
        assert asyncio.run(fetch_remotive()) == []


# --- containment (ADR-003 v5) -------------------------------------------------


def test_disabled_by_default(monkeypatch):
    monkeypatch.setattr(settings, "enable_global_remote", False)
    with patch("services.job_ingestion.fetch_weworkremotely") as wwr, patch(
        "services.job_ingestion.fetch_remotive"
    ) as rem:
        result = asyncio.run(refresh_global_remote())
    assert result["skipped"] == "disabled"
    wwr.assert_not_called()
    rem.assert_not_called()


def test_not_reachable_from_the_run_agent_now_button():
    """ADR-003 keeps these on the daily cron. Landing either in _FREE_SOURCES
    would let any user trigger them on demand by tapping a button — and Remotive
    asks for max ~4 calls/day."""
    from services.job_ingestion import _FREE_SOURCES

    names = {name for name, _ in _FREE_SOURCES}
    assert "weworkremotely" not in names
    assert "remotive" not in names


def test_one_dead_board_still_reports_an_explicit_zero(monkeypatch):
    """A dead source the ops alert cannot see is worse than a dead source."""
    monkeypatch.setattr(settings, "enable_global_remote", True)
    with patch(
        "services.job_ingestion.fetch_weworkremotely",
        AsyncMock(side_effect=RuntimeError("feed down")),
    ), patch("services.job_ingestion.fetch_remotive", AsyncMock(return_value=[])), patch(
        "services.job_ingestion._dedup_embed_insert",
        return_value={"fetched": 0, "inserted": 0},
    ):
        result = asyncio.run(refresh_global_remote())

    assert result["by_source"]["weworkremotely"] == 0
    assert "feed down" in result["errors"]["weworkremotely"]
    assert "remotive" in result["by_source"]


def test_never_retires_on_absence(monkeypatch):
    """The trap this source pair sets. Internshala/Instahyre can treat absence as
    closure because their listing pages are a COMPLETE view of what's open. An
    RSS feed is a rolling window of recent items — a live posting drops out of it
    just by being pushed down by newer ones, so retiring on absence would hide
    open jobs within days."""
    monkeypatch.setattr(settings, "enable_global_remote", True)
    with patch("services.job_ingestion.fetch_weworkremotely", AsyncMock(return_value=[])), patch(
        "services.job_ingestion.fetch_remotive", AsyncMock(return_value=[])
    ), patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}), patch(
        "services.job_ingestion.retire_stale_jobs"
    ) as retire:
        asyncio.run(refresh_global_remote())

    retire.assert_not_called()


def test_sources_resolve_lazily_so_they_stay_patchable():
    """A module-level list literal would bind the function objects at import
    time and silently defeat every patch() above."""
    from services.job_ingestion import _global_remote_sources

    with patch("services.job_ingestion.fetch_remotive", AsyncMock(return_value=[])) as patched:
        assert dict(_global_remote_sources())["remotive"] is patched


def test_gate_override_keeps_entry_level_but_drops_role_and_location():
    """Both fetchers hardcode location="Remote", so the location gate can only
    pass; the role cut would take an already-thin source to zero. Entry-level
    stays because a staff-engineer contract is dead weight in a fresher's pool."""
    from services.job_filter import gates_for_source

    for source in ("weworkremotely", "remotive"):
        assert gates_for_source(source) == frozenset({"entry"})
