"""Phase 4: the notifications endpoints. Supabase is mocked; what's pinned is
the envelope shape — items + unread_count live INSIDE data so the response keeps
the standard {"data", "error"} contract — and that read-all reports how many rows
it cleared."""

import asyncio
from unittest.mock import patch

from routers import notifications


class _FakeResult:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _FakeQuery:
    """Chainable; every builder returns self, execute() returns the preset
    result for whichever call this is (list items vs unread count vs update)."""

    def __init__(self, results: list):
        self._results = results

    def __getattr__(self, _name):
        # select/eq/order/limit/is_/update/insert all just chain.
        return lambda *a, **k: self

    def execute(self):
        return self._results.pop(0)


def _fake_supabase(results):
    q = _FakeQuery(list(results))
    fake = type("S", (), {"table": lambda self, name: q})()
    return patch.object(notifications, "supabase", fake)


def _run(coro):
    return asyncio.run(coro)


def test_list_puts_items_and_unread_count_inside_data():
    items = [{"id": "n1", "read_at": None}, {"id": "n2", "read_at": "2026-07-23T00:00:00Z"}]
    # First execute() → items; second execute() → the count query.
    with _fake_supabase([_FakeResult(items), _FakeResult([], count=1)]):
        out = _run(notifications.list_notifications(profile={"id": "p1"}))
    assert out["error"] is None
    assert set(out["data"]) == {"items", "unread_count"}  # nested, not beside data
    assert out["data"]["items"] == items
    assert out["data"]["unread_count"] == 1


def test_unread_count_falls_back_to_len_when_count_is_none():
    # Some supabase-py versions don't populate .count; the endpoint falls back.
    with _fake_supabase([_FakeResult([]), _FakeResult([{"id": "n1"}, {"id": "n2"}], count=None)]):
        out = _run(notifications.list_notifications(profile={"id": "p1"}))
    assert out["data"]["unread_count"] == 2


def test_read_all_reports_how_many_were_cleared():
    updated = [{"id": "n1"}, {"id": "n2"}, {"id": "n3"}]
    with _fake_supabase([_FakeResult(updated)]):
        out = _run(notifications.mark_all_read(profile={"id": "p1"}))
    assert out["data"] == {"updated": 3}
