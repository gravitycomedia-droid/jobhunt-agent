"""Phase 4 security fixes for the forms router: POST /forms/parse's body is a
StrictModel with a capped URL, and fetch_form_html routes every hop through the
ADR-024 SSRF gate so a form URL can't reach our internal network."""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from models.common import MAX_FORM_HTML_LEN, MAX_URL_LEN
from routers.forms import ParseFormHtmlRequest, ParseFormRequest, _parse_schema_from_html
from services.form_parser import FormAuthRequiredError, FormFetchError, fetch_form_html, parse_google_form


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


# --- sign-in-gated forms: redirect AND direct 401/403 both map the same way -


def test_fetch_form_html_maps_direct_401_to_auth_required():
    """Some sign-in-gated forms answer with a bare 401/403 instead of a
    redirect to accounts.google.com — same reality, different shape on the
    wire. Must raise FormAuthRequiredError (→ the client's open-in-browser
    fallback), not leak the raw httpx.HTTPStatusError as a generic
    FormFetchError."""
    response = MagicMock()
    response.is_redirect = False
    response.raise_for_status.side_effect = httpx.HTTPStatusError(
        "401", request=MagicMock(), response=MagicMock(status_code=401)
    )
    with _resolves_to("93.184.216.34"), patch("httpx.AsyncClient.get", new=AsyncMock(return_value=response)):
        with pytest.raises(FormAuthRequiredError):
            asyncio.run(fetch_form_html("https://forms.gle/abc123"))


def test_fetch_form_html_returns_resolved_url_not_the_original_short_link():
    """ADR-053 bug fix: forms.gle's redirect is a static, pre-registered
    mapping that DROPS any query string appended to the short link — so a
    prefill URL built on top of `forms.gle/xxx?entry.1=y` silently loses every
    entry param on that redirect, landing on the real form completely
    unfilled. Every caller must build the prefill URL against the RESOLVED
    url, so fetch_form_html must hand that back, not the original short link."""
    redirect_response = MagicMock()
    redirect_response.is_redirect = True
    redirect_response.headers = {"location": "https://docs.google.com/forms/d/e/real123/viewform"}
    redirect_response.url = httpx.URL("https://forms.gle/shortlink")

    final_response = MagicMock()
    final_response.is_redirect = False
    final_response.url = httpx.URL("https://docs.google.com/forms/d/e/real123/viewform")
    final_response.headers = {"content-type": "text/html; charset=utf-8"}
    final_response.text = "<html>the real form</html>"
    final_response.raise_for_status.return_value = None

    with _resolves_to("93.184.216.34"), patch(
        "httpx.AsyncClient.get", new=AsyncMock(side_effect=[redirect_response, final_response])
    ):
        html, final_url = asyncio.run(fetch_form_html("https://forms.gle/shortlink"))

    assert html == "<html>the real form</html>"
    assert final_url == "https://docs.google.com/forms/d/e/real123/viewform"
    assert final_url != "https://forms.gle/shortlink"


# --- /forms/parse-html (ADR-053): client-fetched HTML for sign-in-gated forms


def test_parse_html_request_rejects_extra_fields():
    with pytest.raises(ValidationError, match="[Ee]xtra"):
        ParseFormHtmlRequest(html="<html></html>", form_url="https://forms.gle/abc", extra="x")


def test_parse_html_request_rejects_empty_and_overlong_fields():
    with pytest.raises(ValidationError):
        ParseFormHtmlRequest(html="", form_url="https://forms.gle/abc")
    with pytest.raises(ValidationError):
        ParseFormHtmlRequest(html="<html></html>", form_url="")
    with pytest.raises(ValidationError):
        ParseFormHtmlRequest(html="x" * (MAX_FORM_HTML_LEN + 1), form_url="https://forms.gle/abc")


_FB_DATA = [None, [None, [[1, "Full name", None, 0, [[10, None, True]]]]], None, "Sign-in Gated Form"]
_GOOGLE_FORM_HTML = f"<html><script>var FB_PUBLIC_LOAD_DATA_ = {json.dumps(_FB_DATA)};</script></html>"
_GATED_FORM_URL = "https://docs.google.com/forms/d/e/gated123/viewform"


def test_parse_schema_from_html_matches_direct_parse_for_google_forms():
    """/forms/parse-html must produce the identical schema /forms/parse would
    for the same HTML — it's the same deterministic parser (services.form_parser
    .parse_google_form), just fed HTML the client fetched instead of HTML the
    server fetched. No new parsing logic to drift out of sync."""
    direct = parse_google_form(_GOOGLE_FORM_HTML, form_url=_GATED_FORM_URL)
    via_router = asyncio.run(
        _parse_schema_from_html(_GOOGLE_FORM_HTML, _GATED_FORM_URL, profile={"id": "irrelevant-for-google-forms"})
    )
    assert via_router.title == direct.title == "Sign-in Gated Form"
    assert [q.entry_id for q in via_router.questions] == [q.entry_id for q in direct.questions] == ["10"]


def test_parse_schema_from_html_still_raises_auth_required_if_html_itself_is_a_signin_page():
    """Belt-and-braces: even HTML the client claims came from a signed-in
    session might actually be Google's sign-in page (e.g. the WebView grabbed
    it a beat too early). parse_google_form's own ServiceLogin check still
    applies here — /parse-html isn't a way to bypass that detection — and the
    router maps it to the same 403 form_auth_required /parse already uses."""
    html = '<html><a href="https://accounts.google.com/v3/signin">Sign in</a>ServiceLogin</html>'
    with pytest.raises(HTTPException) as exc_info:
        asyncio.run(_parse_schema_from_html(html, _GATED_FORM_URL, profile={"id": "irrelevant"}))
    assert exc_info.value.status_code == 403
    assert "form_auth_required" in exc_info.value.detail
