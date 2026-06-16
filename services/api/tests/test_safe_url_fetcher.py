"""Tests for SafeURLFetcher SSRF protection."""

import socket

import httpx
import pytest

from api.processing.safe_url_fetcher import SafeURLFetcher, SSRFError


def _make_resolver(ip: str):
    """Create a mock resolver that returns the given IP."""

    def resolver(hostname, port, family, socktype):
        return [(family, socktype, 0, "", (ip, 0))]

    return resolver


def _make_multi_resolver(ips: list[str]):
    """Create a mock resolver that returns multiple IPs."""

    def resolver(hostname, port, family, socktype):
        return [(family, socktype, 0, "", (ip, 0)) for ip in ips]

    return resolver


def _make_failing_resolver():
    """Create a mock resolver that raises a DNS failure."""

    def resolver(hostname, port, family, socktype):
        raise socket.gaierror("Name or service not known")

    return resolver


class TestSchemeValidation:
    """Tests for URL scheme validation."""

    def test_http_allowed(self) -> None:
        """http:// should pass scheme validation."""
        fetcher = SafeURLFetcher(resolver=_make_resolver("93.184.216.34"))
        # _validate_url should not raise
        fetcher._validate_url("http://example.com/page")

    def test_https_allowed(self) -> None:
        """https:// should pass scheme validation."""
        fetcher = SafeURLFetcher(resolver=_make_resolver("93.184.216.34"))
        fetcher._validate_url("https://example.com/page")

    def test_file_scheme_rejected(self) -> None:
        """file:// should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="Scheme not allowed: file"):
            fetcher._validate_url("file:///etc/passwd")

    def test_ftp_scheme_rejected(self) -> None:
        """ftp:// should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="Scheme not allowed: ftp"):
            fetcher._validate_url("ftp://ftp.example.com/file")

    def test_gopher_scheme_rejected(self) -> None:
        """gopher:// should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="Scheme not allowed: gopher"):
            fetcher._validate_url("gopher://example.com/resource")

    def test_javascript_scheme_rejected(self) -> None:
        """javascript: should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="Scheme not allowed"):
            fetcher._validate_url("javascript:alert(1)")

    def test_empty_scheme_rejected(self) -> None:
        """URL without scheme should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="Scheme not allowed"):
            fetcher._validate_url("example.com/page")

    def test_url_too_long(self) -> None:
        """URL > 2048 chars should be rejected."""
        long_url = "https://example.com/" + "a" * 2030
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="URL too long"):
            fetcher._validate_url(long_url)

    def test_url_no_hostname(self) -> None:
        """URL with no hostname should be rejected."""
        fetcher = SafeURLFetcher()
        with pytest.raises(SSRFError, match="no hostname"):
            fetcher._validate_url("http://")


class TestPrivateIPBlocking:
    """Tests for private/reserved IP range blocking."""

    @pytest.mark.parametrize(
        "ip,description",
        [
            ("10.0.0.1", "10.0.0.0/8 class A private"),
            ("10.255.255.255", "10.0.0.0/8 upper bound"),
            ("172.16.0.1", "172.16.0.0/12 class B private"),
            ("172.31.255.255", "172.16.0.0/12 upper bound"),
            ("192.168.0.1", "192.168.0.0/16 class C private"),
            ("192.168.255.255", "192.168.0.0/16 upper bound"),
            ("127.0.0.1", "127.0.0.0/8 loopback"),
            ("127.255.255.255", "127.0.0.0/8 upper bound"),
            ("169.254.0.1", "169.254.0.0/16 link-local"),
            ("169.254.255.255", "169.254.0.0/16 upper bound"),
        ],
    )
    def test_private_ipv4_blocked(self, ip: str, description: str) -> None:
        """All private IPv4 ranges should be blocked."""
        fetcher = SafeURLFetcher(resolver=_make_resolver(ip))
        with pytest.raises(SSRFError, match="private IP"):
            fetcher._resolve_and_validate_host("evil.example.com")

    def test_ipv6_loopback_blocked(self) -> None:
        """::1 (IPv6 loopback) should be blocked."""
        fetcher = SafeURLFetcher(resolver=_make_resolver("::1"))
        with pytest.raises(SSRFError, match="private IP"):
            fetcher._resolve_and_validate_host("evil.example.com")

    def test_public_ip_allowed(self) -> None:
        """Public IPs should pass validation."""
        fetcher = SafeURLFetcher(resolver=_make_resolver("93.184.216.34"))
        # Should not raise
        fetcher._resolve_and_validate_host("example.com")

    def test_public_ip_8_8_8_8_allowed(self) -> None:
        """Google DNS (8.8.8.8) should pass."""
        fetcher = SafeURLFetcher(resolver=_make_resolver("8.8.8.8"))
        fetcher._resolve_and_validate_host("dns.google")

    def test_multiple_ips_one_private_blocked(self) -> None:
        """If any resolved IP is private, the request is blocked."""
        fetcher = SafeURLFetcher(resolver=_make_multi_resolver(["93.184.216.34", "10.0.0.1"]))
        with pytest.raises(SSRFError, match="private IP"):
            fetcher._resolve_and_validate_host("dual.example.com")

    def test_dns_failure_raises(self) -> None:
        """DNS resolution failure should raise SSRFError."""
        fetcher = SafeURLFetcher(resolver=_make_failing_resolver())
        with pytest.raises(SSRFError, match="DNS resolution failed"):
            fetcher._resolve_and_validate_host("nonexistent.invalid")


class TestResponseSizeCap:
    """Tests for response body size limiting."""

    def test_small_response_allowed(self) -> None:
        """Response under 1MB should pass."""
        fetcher = SafeURLFetcher()
        response = httpx.Response(200, content=b"x" * 1000)
        result = fetcher._read_response_with_cap(response)
        assert len(result) == 1000

    def test_response_at_1mb_allowed(self) -> None:
        """Response at exactly 1MB should pass."""
        fetcher = SafeURLFetcher()
        content = b"x" * (1024 * 1024)
        response = httpx.Response(200, content=content)
        result = fetcher._read_response_with_cap(response)
        assert len(result) == 1024 * 1024

    def test_response_over_1mb_rejected(self) -> None:
        """Response over 1MB should raise SSRFError."""
        fetcher = SafeURLFetcher()
        content = b"x" * (1024 * 1024 + 1)
        response = httpx.Response(200, content=content)
        with pytest.raises(SSRFError, match="exceeds 1MB"):
            fetcher._read_response_with_cap(response)


class TestRedirectValidation:
    """Tests for redirect re-validation."""

    @pytest.mark.anyio
    async def test_redirect_to_private_ip_blocked(self) -> None:
        """Redirect to a private IP should be blocked."""
        call_count = {"resolve": 0}

        def resolver(hostname, port, family, socktype):
            call_count["resolve"] += 1
            if call_count["resolve"] == 1:
                # Initial URL resolves to public IP
                return [(family, socktype, 0, "", ("93.184.216.34", 0))]
            # Redirect target resolves to private IP
            return [(family, socktype, 0, "", ("10.0.0.1", 0))]

        def redirect_handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                302,
                headers={"location": "http://internal.corp/secret"},
            )

        transport = httpx.MockTransport(redirect_handler)
        fetcher = SafeURLFetcher(resolver=resolver, transport=transport)

        with pytest.raises(SSRFError, match="private IP"):
            await fetcher.fetch("http://evil.example.com/redirect")

    @pytest.mark.anyio
    async def test_too_many_redirects_blocked(self) -> None:
        """More than MAX_REDIRECTS should be blocked."""
        redirect_count = {"n": 0}

        def redirect_loop(request: httpx.Request) -> httpx.Response:
            redirect_count["n"] += 1
            return httpx.Response(
                302,
                headers={"location": f"http://example.com/hop{redirect_count['n']}"},
            )

        transport = httpx.MockTransport(redirect_loop)
        fetcher = SafeURLFetcher(
            resolver=_make_resolver("93.184.216.34"),
            transport=transport,
        )

        with pytest.raises(SSRFError, match="Too many redirects"):
            await fetcher.fetch("http://example.com/loop")


class TestFetchIntegration:
    """Integration tests using httpx mock transport."""

    @pytest.mark.anyio
    async def test_successful_fetch(self) -> None:
        """Successful fetch returns content and metadata."""
        transport = httpx.MockTransport(
            lambda request: httpx.Response(
                200,
                content=b"Hello World",
                headers={"content-type": "text/html"},
            )
        )

        fetcher = SafeURLFetcher(
            resolver=_make_resolver("93.184.216.34"),
            transport=transport,
        )

        result = await fetcher.fetch("https://example.com/page")
        assert result.content == b"Hello World"
        assert result.content_type == "text/html"
        assert result.final_url == "https://example.com/page"

    @pytest.mark.anyio
    async def test_fetch_with_successful_redirect(self) -> None:
        """Successful redirect follows to final URL."""
        call_count = {"n": 0}

        def handler(request: httpx.Request) -> httpx.Response:
            call_count["n"] += 1
            if call_count["n"] == 1:
                return httpx.Response(
                    301,
                    headers={"location": "https://example.com/final"},
                )
            return httpx.Response(
                200,
                content=b"Final content",
                headers={"content-type": "text/plain"},
            )

        transport = httpx.MockTransport(handler)
        fetcher = SafeURLFetcher(
            resolver=_make_resolver("93.184.216.34"),
            transport=transport,
        )

        result = await fetcher.fetch("https://example.com/old")
        assert result.content == b"Final content"
        assert result.final_url == "https://example.com/final"


class TestIsPrivateIP:
    """Direct tests for the _is_private_ip method."""

    @pytest.mark.parametrize(
        "ip,expected",
        [
            ("10.0.0.1", True),
            ("172.16.0.1", True),
            ("172.31.255.255", True),
            ("172.32.0.1", False),  # Just outside 172.16.0.0/12
            ("192.168.1.1", True),
            ("192.169.1.1", False),  # Just outside 192.168.0.0/16
            ("127.0.0.1", True),
            ("169.254.169.254", True),  # AWS metadata endpoint
            ("8.8.8.8", False),
            ("1.1.1.1", False),
            ("93.184.216.34", False),
            ("::1", True),
        ],
    )
    def test_ip_classification(self, ip: str, expected: bool) -> None:
        """Private IPs should be correctly classified."""
        fetcher = SafeURLFetcher()
        assert fetcher._is_private_ip(ip) is expected
