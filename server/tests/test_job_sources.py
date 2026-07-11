import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import httpx

from config import settings
from services.job_sources import fetch_greenhouse, fetch_lever


def _response(payload: dict | list) -> MagicMock:
    resp = MagicMock()
    resp.json.return_value = payload
    resp.raise_for_status = MagicMock()
    return resp


def test_fetch_greenhouse_maps_fields_and_strips_html(monkeypatch):
    monkeypatch.setattr(settings, "greenhouse_boards", "acme")
    payload = {
        "jobs": [
            {
                "id": 123,
                "title": "Backend Engineer",
                "company_name": "Acme Corp",
                "location": {"name": "Bengaluru, India"},
                # Greenhouse's content is HTML whose own tags are themselves
                # entity-encoded — verified live against the postman board.
                "content": "&lt;p&gt;Build &lt;strong&gt;things&lt;/strong&gt;.&lt;/p&gt;",
                "absolute_url": "https://job-boards.greenhouse.io/acme/jobs/123",
                "updated_at": "2026-07-01T00:00:00-04:00",
            }
        ]
    }
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_response(payload))):
        jobs = asyncio.run(fetch_greenhouse())

    assert len(jobs) == 1
    job = jobs[0]
    assert job.source == "greenhouse"
    assert job.external_id == "123"
    assert job.title == "Backend Engineer"
    assert job.company == "Acme Corp"
    assert job.location == "Bengaluru, India"
    assert job.description == "Build things ."
    assert job.redirect_url == "https://job-boards.greenhouse.io/acme/jobs/123"
    assert job.salary_min is None
    assert job.salary_currency is None


def test_fetch_greenhouse_skips_board_on_http_error(monkeypatch):
    monkeypatch.setattr(settings, "greenhouse_boards", "deadboard,liveboard")
    dead_resp = MagicMock()
    dead_resp.raise_for_status.side_effect = httpx.HTTPStatusError("404", request=MagicMock(), response=MagicMock())
    live_payload = {
        "jobs": [
            {
                "id": 1,
                "title": "Role",
                "company_name": "Acme",
                "location": {"name": "Remote"},
                "content": None,
                "absolute_url": "https://job-boards.greenhouse.io/liveboard/jobs/1",
                "updated_at": "2026-07-01T00:00:00-04:00",
            }
        ]
    }
    with patch(
        "httpx.AsyncClient.get",
        new=AsyncMock(side_effect=[dead_resp, _response(live_payload)]),
    ):
        jobs = asyncio.run(fetch_greenhouse())

    # The dead board's error doesn't sink the refresh — the live board's
    # job still comes through.
    assert len(jobs) == 1
    assert jobs[0].company == "Acme"


def test_fetch_lever_maps_fields_and_converts_epoch_millis(monkeypatch):
    monkeypatch.setattr(settings, "lever_companies", "acme:Acme Corp")
    payload = [
        {
            "id": "abc-123",
            "text": "Product Designer",
            "categories": {"location": "bengaluru", "commitment": "full time"},
            "descriptionPlain": "Design great products.",
            "hostedUrl": "https://jobs.lever.co/acme/abc-123",
            "createdAt": 1751328000000,  # 2025-07-01T00:00:00Z
        }
    ]
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_response(payload))):
        jobs = asyncio.run(fetch_lever())

    assert len(jobs) == 1
    job = jobs[0]
    assert job.source == "lever"
    assert job.external_id == "abc-123"
    assert job.title == "Product Designer"
    assert job.company == "Acme Corp"
    assert job.location == "bengaluru"
    assert job.description == "Design great products."
    assert job.redirect_url == "https://jobs.lever.co/acme/abc-123"
    assert job.posted_at is not None
    assert job.posted_at.year == 2025


def test_lever_companies_display_name_falls_back_to_slug(monkeypatch):
    monkeypatch.setattr(settings, "lever_companies", "acme")
    payload = [
        {
            "id": "x",
            "text": "Role",
            "categories": {},
            "descriptionPlain": None,
            "hostedUrl": None,
            "createdAt": None,
        }
    ]
    with patch("httpx.AsyncClient.get", new=AsyncMock(return_value=_response(payload))):
        jobs = asyncio.run(fetch_lever())

    assert jobs[0].company == "acme"
    assert jobs[0].posted_at is None
