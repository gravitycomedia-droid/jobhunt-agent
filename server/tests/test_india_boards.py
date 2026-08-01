"""Internshala + Instahyre direct-fetch sources (ADR-003 v4).

Both fixtures are REAL responses captured live on 2026-07-27 and trimmed, never
hand-shaped — the whole point of a fixture here is to fail when the markup or the
JSON schema drifts, which a synthetic one can't do.

The things a reviewer should look hardest at:
  1. Containment — these are free, but ADR-003 still allows them only on the
     daily cron. Free of COST is not free of CADENCE.
  2. Retirement safety — an empty seen-set must never wipe a source, and a
     revived posting must come back.
  3. Money — Internshala monthly stipends annualize and stay INR, never "$".
"""

import asyncio
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from config import settings
from services.job_sources import (
    INSTAHYRE_JOB_TYPES,
    _instahyre_row_to_job,
    _internshala_posted_at,
    fetch_instahyre,
    parse_internshala_html,
)

FIXTURES = Path(__file__).parent / "fixtures"
INTERNSHALA_HTML = (FIXTURES / "internshala_listing.html").read_text()


# --- Internshala: HTML parsing ------------------------------------------------


def test_parses_every_card_in_the_fixture():
    jobs = parse_internshala_html(INTERNSHALA_HTML)
    assert len(jobs) == 4
    assert {j.source for j in jobs} == {"internshala"}
    # internshipid attribute, not a content hash or a URL slug.
    assert all(j.external_id.isdigit() for j in jobs)


def test_maps_the_card_fields():
    job = next(j for j in parse_internshala_html(INTERNSHALA_HTML) if j.external_id == "3222142")
    assert job.title == "Internet Of Things (IoT)"
    assert job.company == "Gateway Software Solutions"
    # A 14-city listing collapses to one canonical city so cross-source dedup
    # can fire at all.
    assert job.location == "Chennai"
    assert job.redirect_url.startswith("https://internshala.com/internship/detail/")
    # Skill chips are prepended to the JD — for this source they're the cleanest
    # signal the embedding and the category classifier get.
    assert job.description.startswith("Skills: Python, Raspberry Pi")


def test_monthly_stipend_annualizes_and_stays_inr():
    # "₹ 3,000 - 12,000 /month" → x12, so it sits on the same axis as a per-year
    # salary. India-only source: currency must never fall back to USD.
    job = next(j for j in parse_internshala_html(INTERNSHALA_HTML) if j.external_id == "3222142")
    assert (job.salary_min, job.salary_max) == (36_000, 144_000)
    assert job.salary_currency == "INR"


def test_malformed_card_is_skipped_not_fatal():
    markup = '<div class="individual_internship">no id, no title</div>' + INTERNSHALA_HTML
    assert len(parse_internshala_html(markup)) == 4


# --- Internshala: the relative-time badge ------------------------------------


def test_badge_resolves_to_absolute_time():
    now = datetime(2026, 7, 27, 12, 0, tzinfo=timezone.utc)
    assert _internshala_posted_at("Just now", now) == now
    assert _internshala_posted_at("Today", now) == now
    assert _internshala_posted_at("1 day ago", now) == now - timedelta(days=1)
    assert _internshala_posted_at("3 weeks ago", now) == now - timedelta(weeks=3)


def test_unknown_badge_is_none_not_now():
    # An undated posting must not be able to masquerade as fresh. None is the
    # honest answer and is_fresh() already defines what happens to it.
    assert _internshala_posted_at(None) is None
    assert _internshala_posted_at("") is None
    assert _internshala_posted_at("Actively hiring") is None


def test_stale_card_keeps_its_real_date_rather_than_being_dropped_here():
    """Freshness is is_fresh()'s job, not the fetcher's.

    The fixture deliberately contains a "3 weeks ago" card. The fetcher resolves
    its true date and hands it on; the shared ≤max_job_age_days gate in
    _dedup_embed_insert() is what cuts it. Filtering here would make this the one
    source with a private, stricter freshness rule.
    """
    jobs = parse_internshala_html(INTERNSHALA_HTML)
    old = next(j for j in jobs if j.external_id == "3190808")
    assert (datetime.now(timezone.utc) - old.posted_at).days >= 20


def test_cards_are_not_recency_sorted_so_there_is_no_early_stop():
    """Regression guard for a real trap in the source plan.

    The plan specified stopping at the first non-fresh card because listings are
    "sorted newest-first". They are NOT: measured live, the top of the page is a
    promoted/featured block in mixed order — the fixture preserves that, with a
    "3 weeks ago" card sitting ABOVE fresher ones. An early-stop would have
    returned almost nothing. Every card on a fetched page must be parsed.
    """
    jobs = parse_internshala_html(INTERNSHALA_HTML)
    ages = [(datetime.now(timezone.utc) - j.posted_at).days for j in jobs]
    assert ages != sorted(ages), "fixture no longer captures the unsorted case"
    assert len(jobs) == 4


# --- Instahyre: JSON mapping --------------------------------------------------


def _instahyre_row(**overrides) -> dict:
    row = {
        "id": 433884,
        "candidate_title": "Backend Engineer (Internship)",
        "title": "Backend Engineer",
        "locations": "Bangalore,Pune",
        "keywords": ["Software Engineering", "Python", "Django"],
        "public_url": "https://www.instahyre.com/job-433884-backend-engineer/",
        "employer": {"company_name": "Falkor", "instahyre_note": "Industrial intelligence platform."},
        "reviewed_at": None,
    }
    row.update(overrides)
    return row


def test_instahyre_maps_a_row():
    job = _instahyre_row_to_job(_instahyre_row())
    assert job.source == "instahyre"
    assert job.external_id == "433884"
    # candidate_title carries the "(Internship)" suffix the entry-level gate
    # reads, so it beats the plain `title`.
    assert job.title == "Backend Engineer (Internship)"
    assert job.company == "Falkor"
    assert job.redirect_url.endswith("/job-433884-backend-engineer/")


def test_instahyre_locations_are_a_comma_string_not_a_list():
    # Easy field to misread — it's "Bangalore,Pune", not ["Bangalore","Pune"].
    job = _instahyre_row_to_job(_instahyre_row(locations="Bangalore,Noida,Pune"))
    assert job.location == "Bangalore"


def test_instahyre_keywords_become_the_description():
    # The search response carries no JD text at all, so the skill tags plus the
    # employer blurb ARE what gets embedded.
    job = _instahyre_row_to_job(_instahyre_row())
    assert "Python, Django" in job.description
    assert "Industrial intelligence platform." in job.description


def test_instahyre_has_no_posting_date():
    """`reviewed_at` looks like a date but is a candidate-interaction field,
    always null on a public query. posted_at must stay None rather than being
    invented — freshness for this source is decided by dedup instead."""
    job = _instahyre_row_to_job(_instahyre_row(reviewed_at="2026-07-27T00:00:00Z"))
    assert job.posted_at is None


def test_instahyre_skips_rows_missing_id_or_title():
    assert _instahyre_row_to_job({}) is None
    assert _instahyre_row_to_job({"id": 1}) is None
    assert _instahyre_row_to_job({"candidate_title": "No id"}) is None


# --- Instahyre: pagination ----------------------------------------------------


def _page(objects: list, next_path: str | None = None) -> MagicMock:
    resp = MagicMock()
    resp.json.return_value = {"objects": objects, "meta": {"next": next_path, "total_count": len(objects)}}
    resp.raise_for_status = MagicMock()
    return resp


def test_instahyre_follows_meta_next_until_null():
    pages = [
        _page([_instahyre_row(id=1)], next_path="/api/v1/job_search?offset=50"),
        _page([_instahyre_row(id=2)], next_path=None),
        # Second job_type crawl.
        _page([_instahyre_row(id=3)], next_path=None),
    ]
    with patch("httpx.AsyncClient.get", new=AsyncMock(side_effect=pages)):
        jobs = asyncio.run(fetch_instahyre(max_results=100))
    assert [j.external_id for j in jobs] == ["1", "2", "3"]


def test_instahyre_dedups_across_the_two_job_types():
    # The full-time and internship crawls can surface the same posting; the
    # `fetched` count must not double-count it.
    same = _page([_instahyre_row(id=7)], next_path=None)
    with patch("httpx.AsyncClient.get", new=AsyncMock(side_effect=[same, same])):
        jobs = asyncio.run(fetch_instahyre(max_results=100))
    assert [j.external_id for j in jobs] == ["7"]


def test_internships_are_fetched_before_full_time():
    """Regression for the first production run, which inserted 0 Instahyre rows.

    Both job types share one cap. Full-time is ~7,900 rows and ~100% of it is
    rejected by the entry-level gate; internships are ~8 rows and mostly survive.
    With full-time crawled first it ate the entire budget and the internship
    catalogue — the only part that can pass the gate — was never requested.
    """
    assert INSTAHYRE_JOB_TYPES[0] == 2, "internships must be crawled first"

    calls: list[str] = []

    async def _get(self, url, *a, **kw):
        calls.append(url)
        return _page([_instahyre_row(id=len(calls))], next_path=None)

    with patch("httpx.AsyncClient.get", new=_get):
        asyncio.run(fetch_instahyre(max_results=100))

    assert "job_type=2" in calls[0], f"first request must be internships, got {calls[0]}"


def test_a_huge_full_time_catalogue_cannot_starve_internships():
    # The exact production shape: full-time paginates on and on, internships are
    # one small page. The cap must not be spent before internships are asked for.
    counter = {"n": 0}

    async def _get(self, url, *a, **kw):
        if "job_type=2" in url:
            return _page([_instahyre_row(id=9001)], next_path=None)
        counter["n"] += 1
        base = counter["n"] * 100
        return _page(
            [_instahyre_row(id=base + i) for i in range(50)],
            next_path="/api/v1/job_search?offset=next",
        )

    with patch("httpx.AsyncClient.get", new=_get):
        jobs = asyncio.run(fetch_instahyre(max_results=60))

    assert "9001" in {j.external_id for j in jobs}, "internship listing was starved by the full-time crawl"


def test_pagination_terminates_when_a_source_repeats_itself():
    """The row cap is not a termination guarantee on its own.

    New rows are deduped by id before being counted, so an endpoint that keeps
    returning `meta.next` with content we've already seen never grows len(jobs)
    and the crawl spins forever. This exact shape hung the test suite; the page
    ceiling is what bounds it.
    """
    async def _get(self, url, *a, **kw):
        # Same ids on every page, and never a null `next`. Ids start at 1: id=0
        # is falsy and is correctly dropped as a missing id, which would make the
        # count below quietly off by one for an unrelated reason.
        return _page([_instahyre_row(id=i) for i in range(1, 51)], next_path="/api/v1/job_search?offset=loop")

    with patch("httpx.AsyncClient.get", new=_get):
        jobs = asyncio.run(fetch_instahyre(max_results=10_000))

    # Terminated rather than hung, and returned the distinct rows it did see.
    assert len(jobs) == 50


def test_instahyre_respects_the_cap():
    many = _page([_instahyre_row(id=i) for i in range(50)], next_path="/api/v1/job_search?offset=50")
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=many)):
        jobs = asyncio.run(fetch_instahyre(max_results=10))
    assert len(jobs) == 10


def test_instahyre_page_failure_returns_what_it_has():
    import httpx

    with patch("httpx.AsyncClient.get", new=AsyncMock(side_effect=httpx.ReadTimeout("t"))):
        assert asyncio.run(fetch_instahyre(max_results=100)) == []


# --- Containment: free of COST is not free of CADENCE -------------------------


def test_neither_source_is_reachable_from_the_user_triggered_path():
    """ADR-003: these boards may only be hit by the daily cron. refresh_job_pool()
    is what the app's "Run agent now" button calls, so a source appearing in its
    _FREE_SOURCES list would let any user trigger scraping on demand."""
    from services.job_ingestion import _FREE_SOURCES

    assert {name for name, _ in _FREE_SOURCES} == {"adzuna", "jsearch", "greenhouse", "lever"}


def test_india_boards_are_gated_by_the_master_switch(monkeypatch):
    from services.job_ingestion import refresh_india_boards

    monkeypatch.setattr(settings, "enable_india_sources", False)
    result = asyncio.run(refresh_india_boards())
    assert result["skipped"] == "disabled"
    assert result["fetched"] == 0


def test_one_board_failing_does_not_sink_the_other(monkeypatch):
    from services.job_ingestion import refresh_india_boards

    monkeypatch.setattr(settings, "enable_india_sources", True)
    good = parse_internshala_html(INTERNSHALA_HTML)
    with (
        patch("services.job_ingestion.fetch_internshala", new=AsyncMock(return_value=good)),
        patch("services.job_ingestion.fetch_instahyre", new=AsyncMock(side_effect=RuntimeError("boom"))),
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 4, "inserted": 4}),
        patch("services.job_ingestion.retire_stale_jobs", return_value={"retired": 0, "revived": 0}),
    ):
        result = asyncio.run(refresh_india_boards())

    # Health tracks FETCHED per source, and the dead one is an explicit 0 with an
    # error rather than a missing key — a dead source the alert can't see is
    # worse than a dead source.
    assert result["by_source"]["internshala"] == 4
    assert result["by_source"]["instahyre"] == 0
    assert "RuntimeError" in result["errors"]["instahyre"]


def test_a_failed_fetch_never_retires_that_source(monkeypatch):
    """The specific disaster this guards: instahyre raises, returns no ids, and
    retirement reads that as "the whole board is empty" and deactivates every
    Instahyre row we have."""
    from services.job_ingestion import refresh_india_boards

    monkeypatch.setattr(settings, "enable_india_sources", True)
    retire = MagicMock(return_value={"retired": 0, "revived": 0})
    with (
        patch("services.job_ingestion.fetch_internshala", new=AsyncMock(return_value=[])),
        patch("services.job_ingestion.fetch_instahyre", new=AsyncMock(side_effect=RuntimeError("boom"))),
        patch("services.job_ingestion._dedup_embed_insert", return_value={"fetched": 0, "inserted": 0}),
        patch("services.job_ingestion.retire_stale_jobs", new=retire),
    ):
        asyncio.run(refresh_india_boards())

    assert "instahyre" not in {call.args[0] for call in retire.call_args_list}


# --- Retirement ---------------------------------------------------------------


def _supabase_with(rows: list[dict]):
    """A supabase double whose select() chain yields `rows` and whose update()
    chain records what it was asked to set."""
    updates: list[tuple[bool, list]] = []

    table = MagicMock()
    select_chain = MagicMock()
    select_chain.eq.return_value = select_chain
    select_chain.execute.return_value = MagicMock(data=rows)
    table.select.return_value = select_chain

    def _update(payload):
        chain = MagicMock()

        def _in(_col, ids):
            updates.append((payload["is_active"], list(ids)))
            result = MagicMock()
            result.execute.return_value = MagicMock(data=[{"id": i} for i in ids])
            return result

        chain.in_.side_effect = _in
        return chain

    table.update.side_effect = _update
    client = MagicMock()
    client.table.return_value = table
    return client, updates


def test_retirement_deactivates_only_the_rows_that_vanished():
    from services import job_ingestion

    rows = [
        {"id": "a", "external_id": "1", "is_active": True},  # still listed
        {"id": "b", "external_id": "2", "is_active": True},  # gone → retire
    ]
    client, updates = _supabase_with(rows)
    with patch.object(job_ingestion, "supabase", client):
        result = job_ingestion.retire_stale_jobs("internshala", {"1"})

    assert result["retired"] == 1
    assert updates == [(False, ["b"])]


def test_retirement_is_soft_and_never_deletes():
    from services import job_ingestion

    rows = [{"id": "b", "external_id": "2", "is_active": True}]
    client, _ = _supabase_with(rows)
    with patch.object(job_ingestion, "supabase", client):
        job_ingestion.retire_stale_jobs("internshala", {"1"})

    # A jobs row is referenced by applications/matches/tailored_resumes; deleting
    # one would destroy a user's tracked history because a company took a listing
    # down. Retirement must only ever flip a flag.
    assert not client.table.return_value.delete.called


def test_empty_seen_set_is_treated_as_a_failed_fetch():
    from services import job_ingestion

    rows = [{"id": "a", "external_id": "1", "is_active": True}]
    client, updates = _supabase_with(rows)
    with patch.object(job_ingestion, "supabase", client):
        result = job_ingestion.retire_stale_jobs("instahyre", set())

    assert result["skipped"] == "empty_seen_set"
    assert updates == []


def test_a_reappearing_posting_is_revived():
    """Not optional. The main insert upserts with ignore_duplicates=True, so a
    row retired yesterday that is live again today is skipped by the upsert and
    would stay invisible forever. Retirement is only safe because it reverses."""
    from services import job_ingestion

    rows = [{"id": "a", "external_id": "1", "is_active": False}]
    client, updates = _supabase_with(rows)
    with patch.object(job_ingestion, "supabase", client):
        result = job_ingestion.retire_stale_jobs("internshala", {"1"})

    assert result["revived"] == 1
    assert updates == [(True, ["a"])]


# --- entry-level hint: structural knowledge beats guessing from wording -------


def test_internships_stem_marks_listings_entry_level():
    """Internshala card titles are PROFILE names ("Android App Development"),
    not job titles — measured live, only 3 of 50 contain the word "intern". So
    the text-based seniority check rejected ~38% of listings fetched from the
    /internships/ URL, every one of which is an internship by definition.

    The fetcher knows which stem it requested; it must say so rather than leave
    the gate to infer what the markup never states.
    """
    jobs = parse_internshala_html(INTERNSHALA_HTML, entry_level_hint=True)
    assert jobs and all(j.entry_level_hint is True for j in jobs)


def test_the_hint_defaults_to_none_so_other_callers_are_unaffected():
    jobs = parse_internshala_html(INTERNSHALA_HTML)
    assert all(j.entry_level_hint is None for j in jobs)


def test_hint_rescues_an_internship_whose_title_never_says_intern():
    from services.job_filter import is_entry_level, is_relevant

    title = "Android App Development"  # a real Internshala profile name
    # The text check genuinely cannot tell — that is the whole problem.
    assert is_entry_level(title, None) is False
    assert is_relevant(title, "Remote", None, source="internshala") is False
    assert is_relevant(title, "Remote", None, source="internshala", entry_level_hint=True) is True


def test_hint_never_leaks_into_the_database_payload():
    """LOAD-BEARING. JobIn.model_dump() is written straight into the `jobs`
    upsert, so a field without a matching column would make PostgREST reject the
    entire batch — turning a filtering improvement into a total ingestion
    outage."""
    from models.job import JobIn

    job = JobIn(source="internshala", external_id="1", title="X", entry_level_hint=True)
    assert job.entry_level_hint is True
    assert "entry_level_hint" not in job.model_dump(mode="json")


def test_fresher_jobs_stem_does_not_get_the_hint():
    # Despite the name, /fresher-jobs/ is full-time roles and does carry the odd
    # experienced posting — it must keep going through the normal text check.
    from services.job_sources import fetch_internshala
    import services.job_sources as js

    assert js.INTERNSHALA_BASE  # sanity
    # The stem table is built inside fetch_internshala; assert the contract it
    # encodes rather than reaching into the function.
    import inspect

    src = inspect.getsource(fetch_internshala)
    assert '("fresher-jobs", "{base}/fresher-jobs/{slug}-jobs/", None)' in src
