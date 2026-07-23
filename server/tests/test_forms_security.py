"""Phase 4 security fixes for the forms router: POST /forms/parse's body is a
StrictModel with a capped URL, and fetch_form_html routes every hop through the
ADR-024 SSRF gate so a form URL can't reach our internal network."""

import asyncio
from unittest.mock import patch

import pytest
from pydantic import ValidationError

from models.common import MAX_URL_LEN
from routers.forms import ParseFormRequest
from services.form_parser import FormFetchError, fetch_form_html


# --- request hardening -----------------------------------------------------


def test_parse_request_rejects_extra_fields():
    with pytest.raises(ValidationError, match="[Ee]xtra"):
        ParseFormRequest(url="https://forms.gle/abc", follow_redirects_to="http://169.254.169.254")


def test_parse_request_rejects_empty_and_overlong_url():
    with pytest.raises(ValidationError):
        ParseFormRequest(url="")
    with pytest.raises(ValidationError):
        ParseFormRequest(url="https://x.example.com/" + "a" * MAX_URL_LEN)


def test_parse_request_accepts_a_normal_url():
    assert ParseFormRequest(url="https://forms.gle/abc").url == "https://forms.gle/abc"


# --- SSRF: a form URL resolving to a private address is refused -------------


def _resolves_to(ip: str):
    return patch(
        "services.job_ingestion.socket.getaddrinfo",
        return_value=[(2, 1, 6, "", (ip, 80))],
    )


@pytest.mark.parametrize("ip", ["169.254.169.254", "127.0.0.1", "10.0.0.5", "::1"])
def test_fetch_form_html_blocks_private_addresses(ip):
    with _resolves_to(ip):
        with pytest.raises(FormFetchError, match="private or internal"):
            asyncio.run(fetch_form_html("http://sneaky.example.com/form"))
