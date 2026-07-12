"""ADR-024: the manual-job URL fetch must not become an SSRF into our own
network. _assert_public_url is the gate; these tests pin the cases that matter
most (the cloud metadata endpoint, loopback, private ranges, bad schemes)."""

from unittest.mock import patch

import pytest

from services.job_ingestion import ManualJobFetchError, _assert_public_url


def _resolves_to(ip: str):
    """Patch getaddrinfo so a hostname 'resolves' to a chosen IP without DNS."""
    return patch(
        "services.job_ingestion.socket.getaddrinfo",
        return_value=[(2, 1, 6, "", (ip, 80))],
    )


@pytest.mark.parametrize(
    "ip",
    [
        "169.254.169.254",  # THE cloud metadata endpoint — the reason this exists
        "127.0.0.1",  # loopback
        "10.0.0.5",  # RFC1918
        "172.16.4.4",  # RFC1918
        "192.168.1.1",  # RFC1918
        "169.254.10.10",  # link-local
        "100.64.0.1",  # CGNAT
        "::1",  # IPv6 loopback
        "fd00::1",  # IPv6 unique-local
    ],
)
def test_rejects_urls_resolving_to_non_public_addresses(ip):
    with _resolves_to(ip):
        with pytest.raises(ManualJobFetchError, match="private or internal"):
            _assert_public_url(f"http://sneaky.example.com/jobs")


def test_allows_a_normal_public_url():
    with _resolves_to("93.184.216.34"):  # example.com
        _assert_public_url("https://boards.example.com/careers/123")  # no raise


@pytest.mark.parametrize("url", ["file:///etc/passwd", "ftp://host/x", "gopher://host", "javascript:alert(1)"])
def test_rejects_non_http_schemes(url):
    with pytest.raises(ManualJobFetchError, match="http"):
        _assert_public_url(url)


def test_rejects_url_with_no_host():
    with pytest.raises(ManualJobFetchError):
        _assert_public_url("http://")


def test_rejects_unresolvable_host():
    import socket

    with patch("services.job_ingestion.socket.getaddrinfo", side_effect=socket.gaierror("nope")):
        with pytest.raises(ManualJobFetchError, match="resolve"):
            _assert_public_url("http://does-not-exist.invalid")


def test_rejects_when_any_resolved_address_is_private():
    """A hostname with one public and one private A record must NOT pass on the
    strength of the public one — every address is checked."""
    both = [(2, 1, 6, "", ("93.184.216.34", 80)), (2, 1, 6, "", ("10.0.0.1", 80))]
    with patch("services.job_ingestion.socket.getaddrinfo", return_value=both):
        with pytest.raises(ManualJobFetchError, match="private or internal"):
            _assert_public_url("http://dual.example.com")
