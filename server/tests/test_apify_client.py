"""run_actor() must never raise — the daily pipeline fans out across several
sources and one flaky actor can't be allowed to sink the rest of the run
(ADR-003, amended). Every test here asserts the same contract: bad input,
bad network, bad response → [] and a log line, not an exception.
"""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from config import settings
from services.apify_client import run_actor

ACTOR = "owner~some-actor"


@pytest.fixture(autouse=True)
def _token(monkeypatch):
    # Every test but the missing-token one needs a token present, and the real
    # .env may not have one — pin it so the suite doesn't depend on the
    # developer's local environment.
    monkeypatch.setattr(settings, "apify_api_token", "test-token")


def _response(payload, status: int = 200) -> MagicMock:
    resp = MagicMock()
    resp.json.return_value = payload
    resp.status_code = status
    resp.raise_for_status = MagicMock()
    return resp


def test_returns_dataset_items_on_success():
    payload = [{"title": "Backend Engineer"}, {"title": "Frontend Engineer"}]
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=_response(payload))):
        items = asyncio.run(run_actor(ACTOR, {"maxResults": 15}))

    assert items == payload


def test_sends_run_input_as_body_and_token_in_header():
    post = AsyncMock(return_value=_response([]))
    with patch("httpx.AsyncClient.post", new=post):
        asyncio.run(run_actor(ACTOR, {"maxResults": 15, "location": "Hyderabad"}))

    _, kwargs = post.call_args
    assert kwargs["json"] == {"maxResults": 15, "location": "Hyderabad"}
    # Golden rule 1: the token authenticates the call but must not end up in a
    # URL, where access logs and tracebacks would capture it.
    assert kwargs["headers"]["Authorization"] == "Bearer test-token"
    url = post.call_args[0][0] if post.call_args[0] else kwargs.get("url", "")
    assert "test-token" not in url


def test_missing_token_returns_empty(monkeypatch):
    monkeypatch.setattr(settings, "apify_api_token", "")
    # No token → don't even make the call (a 401 costs a round-trip to learn
    # something config already knows).
    post = AsyncMock()
    with patch("httpx.AsyncClient.post", new=post):
        assert asyncio.run(run_actor(ACTOR, {})) == []
    post.assert_not_called()


def test_missing_actor_id_returns_empty():
    # An unset APIFY_*_ACTOR_ID means "this source isn't configured", not an
    # error — POSTing to /acts//run-sync would 404 anyway.
    post = AsyncMock()
    with patch("httpx.AsyncClient.post", new=post):
        assert asyncio.run(run_actor("", {})) == []
    post.assert_not_called()


def test_timeout_returns_empty():
    with patch("httpx.AsyncClient.post", new=AsyncMock(side_effect=httpx.ReadTimeout("timed out"))):
        assert asyncio.run(run_actor(ACTOR, {}, timeout_s=1)) == []


def test_http_error_status_returns_empty():
    # 401 (bad/rotated token) is the one the plan's acceptance criteria call
    # out: it must degrade, not crash the pipeline.
    resp = _response({"error": "unauthorized"}, status=401)
    resp.raise_for_status.side_effect = httpx.HTTPStatusError(
        "401", request=MagicMock(), response=resp
    )
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=resp)):
        assert asyncio.run(run_actor(ACTOR, {})) == []


def test_connection_error_returns_empty():
    with patch("httpx.AsyncClient.post", new=AsyncMock(side_effect=httpx.ConnectError("dns"))):
        assert asyncio.run(run_actor(ACTOR, {})) == []


def test_malformed_json_returns_empty():
    resp = _response(None)
    resp.json.side_effect = ValueError("not json")
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=resp)):
        assert asyncio.run(run_actor(ACTOR, {})) == []


def test_empty_dataset_returns_empty():
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=_response([]))):
        assert asyncio.run(run_actor(ACTOR, {})) == []


def test_non_list_body_returns_empty():
    # A half-crashed actor can 200 with an error object instead of the
    # documented array. We don't control the actor's code, so don't trust it.
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=_response({"error": "boom"}))):
        assert asyncio.run(run_actor(ACTOR, {})) == []


def test_non_dict_items_are_skipped():
    payload = [{"title": "Real Job"}, "garbage", None, {"title": "Also Real"}]
    with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=_response(payload))):
        items = asyncio.run(run_actor(ACTOR, {}))

    assert items == [{"title": "Real Job"}, {"title": "Also Real"}]


def test_token_never_appears_in_logs(caplog):
    monkeypatched_secret = "super-secret-token"
    with patch.object(settings, "apify_api_token", monkeypatched_secret):
        resp = _response({"error": "unauthorized"}, status=401)
        resp.raise_for_status.side_effect = httpx.HTTPStatusError(
            "401", request=MagicMock(), response=resp
        )
        with patch("httpx.AsyncClient.post", new=AsyncMock(return_value=resp)):
            with caplog.at_level("WARNING"):
                assert asyncio.run(run_actor(ACTOR, {})) == []

    assert monkeypatched_secret not in caplog.text
