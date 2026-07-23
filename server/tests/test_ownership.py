"""Phase 4: cross-user single-row reads must 404, not leak. Supabase is mocked;
what's under test is that the query is scoped by BOTH id and profile_id and that
an empty result becomes a 404."""

from unittest.mock import patch

import pytest
from fastapi import HTTPException

from services.ownership import fetch_owned_or_404


class _FakeQuery:
    """Chainable stand-in for supabase-py, recording the .eq() filters applied
    so the test can assert profile_id scoping actually happened."""

    def __init__(self, rows, sink):
        self._rows = rows
        self._filters = sink

    def select(self, *a, **k):
        return self

    def eq(self, col, val):
        self._filters[col] = val
        return self

    def limit(self, *a, **k):
        return self

    def execute(self):
        # Only return rows whose id+profile_id match what was filtered on —
        # mirrors the DB actually applying the WHERE clause.
        matched = [r for r in self._rows if all(r.get(c) == v for c, v in self._filters.items())]

        class _R:
            data = matched

        return _R()


def _patch_supabase(rows, sink):
    fake = type("S", (), {"table": lambda self, name: _FakeQuery(rows, sink)})()
    return patch("services.ownership.supabase", fake)


def test_returns_the_row_when_owned():
    sink: dict = {}
    row = {"id": "n1", "profile_id": "me", "title": "hi"}
    with _patch_supabase([row], sink):
        got = fetch_owned_or_404("notifications", "n1", "me")
    assert got == row
    assert sink == {"id": "n1", "profile_id": "me"}  # scoped by both


def test_404_when_row_belongs_to_another_profile():
    sink: dict = {}
    row = {"id": "n1", "profile_id": "someone_else"}
    with _patch_supabase([row], sink):
        with pytest.raises(HTTPException) as exc:
            fetch_owned_or_404("notifications", "n1", "me")
    assert exc.value.status_code == 404


def test_404_when_row_does_not_exist():
    with _patch_supabase([], {}):
        with pytest.raises(HTTPException) as exc:
            fetch_owned_or_404("chat_threads", "missing", "me")
    assert exc.value.status_code == 404
