"""Daily expiry sweep — retire_expired_jobs() (migration 029).

Why this exists: is_fresh() runs only at INGESTION, so nothing aged a row out
afterwards and the pool grew stale indefinitely. Measured live 2026-08-01, 23%
of active rows were already older than the 10-day rule they were admitted
under, and 48 had no posted_at at all so no age rule could ever reach them.

The failure modes worth guarding, in order of how bad they'd be:
  1. Hiding a job that is still OPEN (a stated deadline must beat age).
  2. Retiring a user's own pasted job (they put it there deliberately).
  3. Leaving undated rows immortal (the original bug).
  4. Hard-deleting anything (applications/matches reference these rows).
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

from config import settings

NOW = datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc)


def _row(rid, source="unstop", posted=None, ingested=None, expires=None) -> dict:
    return {
        "id": rid,
        "source": source,
        "posted_at": posted.isoformat() if posted else None,
        "ingested_at": ingested.isoformat() if ingested else None,
        "expires_at": expires.isoformat() if expires else None,
    }


def _supabase_with(rows):
    """Supabase double: select().eq().range() yields `rows` once then empty,
    and update().in_() records the ids it was asked to deactivate."""
    updated: list[str] = []

    table = MagicMock()
    chain = MagicMock()
    chain.eq.return_value = chain
    # First page returns everything; the loop stops because it's under the size.
    chain.range.return_value = MagicMock(execute=MagicMock(return_value=MagicMock(data=rows)))
    table.select.return_value = chain

    def _update(payload):
        node = MagicMock()

        def _in(_col, ids):
            assert payload == {"is_active": False}, "the sweep must only ever soft-delete"
            updated.extend(ids)
            return MagicMock(execute=MagicMock(return_value=MagicMock(data=[{"id": i} for i in ids])))

        node.in_.side_effect = _in
        return node

    table.update.side_effect = _update
    client = MagicMock()
    client.table.return_value = table
    return client, updated


def _sweep(rows, now=NOW):
    from services import job_ingestion

    client, updated = _supabase_with(rows)
    with patch.object(job_ingestion, "supabase", client):
        result = job_ingestion.retire_expired_jobs(now=now)
    return result, updated, client


# --- rule 1: a stated deadline is a fact, and beats age both ways ------------


def test_past_deadline_is_retired():
    rows = [_row("a", expires=NOW - timedelta(days=1))]
    result, updated, _ = _sweep(rows)
    assert updated == ["a"]
    assert result["by_deadline"] == 1


def test_future_deadline_survives_even_when_ancient():
    """The case age would get wrong. Unstop registration windows reach 56 days,
    so a 40-day-old posting can still be open — and the source told us so."""
    rows = [_row("a", posted=NOW - timedelta(days=40), expires=NOW + timedelta(days=5))]
    result, updated, _ = _sweep(rows)
    assert updated == []
    assert result["retired"] == 0


def test_deadline_wins_over_the_age_rule():
    # Young row, but the source says registration already closed.
    rows = [_row("a", posted=NOW - timedelta(days=1), expires=NOW - timedelta(hours=1))]
    _, updated, _ = _sweep(rows)
    assert updated == ["a"]


# --- rule 2: age, only where no deadline was published -----------------------


def test_old_row_without_a_deadline_is_retired():
    rows = [_row("a", source="linkedin", posted=NOW - timedelta(days=settings.job_expiry_days + 1))]
    result, updated, _ = _sweep(rows)
    assert updated == ["a"]
    assert result["by_age"] == 1


def test_row_inside_the_age_window_survives():
    rows = [_row("a", source="linkedin", posted=NOW - timedelta(days=settings.job_expiry_days - 1))]
    _, updated, _ = _sweep(rows)
    assert updated == []


def test_age_threshold_is_looser_than_ingestion_freshness():
    """These answer different questions: max_job_age_days governs what we ADD,
    job_expiry_days governs what we HIDE. Equal values would retire ~24% of the
    pool, much of it still open."""
    assert settings.job_expiry_days > settings.max_job_age_days


# --- rule 3: undated rows must not be immortal -------------------------------


def test_undated_row_ages_out_on_ingested_at():
    """The original bug: 48 rows had no posted_at, so every age rule skipped
    them and they could never be cleaned up by anything."""
    rows = [_row("a", source="greenhouse", posted=None, ingested=NOW - timedelta(days=60))]
    _, updated, _ = _sweep(rows)
    assert updated == ["a"]


def test_undated_but_recently_ingested_row_survives():
    rows = [_row("a", source="greenhouse", posted=None, ingested=NOW - timedelta(days=2))]
    _, updated, _ = _sweep(rows)
    assert updated == []


# --- rule 4: the user's own jobs are untouchable ------------------------------


@pytest.mark.parametrize("source", ["manual", "jd_paste"])
def test_user_added_jobs_never_expire(source):
    """A pasted job was a deliberate act and is usually attached to an
    application being tracked. No external listing governs it, and ageing one
    out would delete something the user put there on purpose."""
    rows = [_row("a", source=source, posted=NOW - timedelta(days=365))]
    _, updated, _ = _sweep(rows)
    assert updated == []


def test_user_added_job_survives_even_with_a_past_deadline():
    rows = [_row("a", source="manual", expires=NOW - timedelta(days=10))]
    _, updated, _ = _sweep(rows)
    assert updated == []


# --- rule 5: soft only ---------------------------------------------------------


def test_sweep_never_deletes():
    # jobs rows are referenced by applications/matches/tailored_resumes; a hard
    # delete would destroy a user's tracked history. (_supabase_with also asserts
    # the update payload is exactly is_active=False.)
    rows = [_row("a", expires=NOW - timedelta(days=1))]
    _, _, client = _sweep(rows)
    assert not client.table.return_value.delete.called


def test_nothing_to_do_is_not_an_error():
    result, updated, _ = _sweep([])
    assert result == {"scanned": 0, "retired": 0, "by_deadline": 0, "by_age": 0}
    assert updated == []


# --- Unstop expiry backfill: the complete-crawl requirement -------------------


def test_backfill_demands_a_complete_crawl():
    """The retirement half is only sound if the crawl saw the WHOLE catalogue.

    The daily crawl stops after two stale pages (~3 requests), so its view is
    partial — treating absence as "closed" against it would retire most of the
    1,217 Unstop rows we hold. This asserts the backfill explicitly opts out of
    that early stop.
    """
    import asyncio
    from unittest.mock import AsyncMock

    from services import job_ingestion

    spy = AsyncMock(return_value=[])
    with patch.object(job_ingestion, "fetch_unstop", new=spy):
        asyncio.run(job_ingestion.backfill_unstop_expiry())

    assert spy.await_args.kwargs.get("stop_when_stale") is False


def test_backfill_refuses_to_act_on_an_empty_crawl():
    """An empty crawl is far more likely a broken fetch than an empty
    catalogue, and 'retire everything' is the worst response to a broken
    fetch — the same refusal retire_stale_jobs() makes."""
    import asyncio
    from unittest.mock import AsyncMock

    from services import job_ingestion

    client, updated = _supabase_with([_row("a")])
    with patch.object(job_ingestion, "fetch_unstop", new=AsyncMock(return_value=[])), patch.object(
        job_ingestion, "supabase", client
    ):
        result = asyncio.run(job_ingestion.backfill_unstop_expiry())

    assert result["skipped"] == "empty_crawl"
    assert updated == []
