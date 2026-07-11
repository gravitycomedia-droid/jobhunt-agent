import asyncio

import pytest
from fastapi import HTTPException

import services.background_tasks as bg


class _FakeQuery:
    def __init__(self, sink: list):
        self._sink = sink
        self._pending: dict | None = None

    def update(self, payload):
        self._pending = payload
        return self

    def eq(self, *_args):
        return self

    def execute(self):
        if self._pending is not None:
            self._sink.append(self._pending)
        return self


class _FakeSupabase:
    """Records every background_tasks status update in order."""

    def __init__(self):
        self.updates: list[dict] = []

    def table(self, name):
        assert name == "background_tasks"
        return _FakeQuery(self.updates)


@pytest.fixture
def fake_db(monkeypatch):
    fake = _FakeSupabase()
    monkeypatch.setattr(bg, "supabase", fake)
    return fake


def _statuses(fake) -> list[str]:
    return [u["status"] for u in fake.updates]


def test_sync_task_runs_pending_to_done(fake_db):
    asyncio.run(bg.run_task("task-1", lambda: {"reranked": 3, "skipped": 2}))
    assert _statuses(fake_db) == ["running", "done"]
    assert fake_db.updates[-1]["result"] == {"reranked": 3, "skipped": 2}
    assert fake_db.updates[-1]["error"] is None


def test_async_task_awaited(fake_db):
    async def work():
        return {"ok": 1}

    asyncio.run(bg.run_task("task-2", work))
    assert _statuses(fake_db) == ["running", "done"]
    assert fake_db.updates[-1]["result"] == {"ok": 1}


def test_failure_records_failed_with_message(fake_db):
    def boom():
        raise ValueError("no shortlist yet")

    asyncio.run(bg.run_task("task-3", boom))  # must not raise
    assert _statuses(fake_db) == ["running", "failed"]
    assert fake_db.updates[-1]["error"] == "no shortlist yet"
    assert fake_db.updates[-1]["result"] is None


def test_http_exception_detail_surfaces(fake_db):
    def boom():
        raise HTTPException(status_code=422, detail="Stored profile has no experience bullets to tailor")

    asyncio.run(bg.run_task("task-4", boom))
    assert _statuses(fake_db) == ["running", "failed"]
    assert fake_db.updates[-1]["error"] == "Stored profile has no experience bullets to tailor"
