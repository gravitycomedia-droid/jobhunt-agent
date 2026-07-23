"""Phase 4: DELETE /account. Supabase is mocked; what's pinned is that the
profile row is deleted (which cascades every owned table) AND the Supabase auth
user is removed — profiles.user_id is a value link, not a FK, so the auth delete
must be explicit. A failed auth delete surfaces as 502, not a silent success."""

import asyncio
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from routers import account


class _FakeProfiles:
    """Chainable stand-in recording the delete + its .eq() scoping."""

    def __init__(self, sink):
        self._sink = sink

    def delete(self):
        self._sink["deleted"] = True
        return self

    def eq(self, col, val):
        self._sink.setdefault("eq", {})[col] = val
        return self

    def execute(self):
        class _R:
            data = []

        return _R()


def _fake_supabase(sink, admin_raises=False):
    fake = MagicMock()
    fake.table.side_effect = lambda name: sink.__setitem__("table", name) or _FakeProfiles(sink)
    if admin_raises:
        fake.auth.admin.delete_user.side_effect = Exception("gotrue down")
    return fake


def _run(coro):
    return asyncio.run(coro)


def test_deletes_profile_and_auth_user():
    sink: dict = {}
    fake = _fake_supabase(sink)
    with patch.object(account, "supabase", fake):
        out = _run(account.delete_account({"id": "p1", "user_id": "u1"}))
    assert out == {"data": {"deleted": True}, "error": None}
    assert sink["table"] == "profiles" and sink["deleted"] is True
    assert sink["eq"] == {"id": "p1"}  # scoped to the caller's profile
    fake.auth.admin.delete_user.assert_called_once_with("u1")


def test_auth_delete_failure_is_a_502_not_a_silent_pass():
    sink: dict = {}
    fake = _fake_supabase(sink, admin_raises=True)
    with patch.object(account, "supabase", fake):
        with pytest.raises(HTTPException) as exc:
            _run(account.delete_account({"id": "p1", "user_id": "u1"}))
    assert exc.value.status_code == 502
    assert sink["deleted"] is True  # data was still removed before the auth step


def test_missing_user_id_skips_auth_delete():
    sink: dict = {}
    fake = _fake_supabase(sink)
    with patch.object(account, "supabase", fake):
        out = _run(account.delete_account({"id": "p1"}))  # no user_id
    assert out["data"]["deleted"] is True
    fake.auth.admin.delete_user.assert_not_called()
