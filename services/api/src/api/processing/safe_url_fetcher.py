"""SSRF-safe URL fetcher for the processing worker.

Validates URL scheme, resolves DNS to reject private IPs,
re-validates each redirect hop, and caps response size at 1MB.
"""

import ipaddress
import socket
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlparse

import httpx
import structlog

logger = structlog.get_logger("api.processing.safe_url_fetcher")

# Type for the DNS resolver callable (same signature as socket.getaddrinfo)
DnsResolver = Callable[[str, None, int, int], list[tuple]]


class SSRFError(Exception):
    """Raised when a URL targets a forbidden destination."""

    pass


@dataclass(frozen=True)
class FetchResult:
    """Result of a safe URL fetch."""

    content: bytes
    final_url: str
    content_type: str


class SafeURLFetcher:
    """Fetches URLs with SSRF protections.

    Protections applied:
    - Scheme validation (http/https only)
    - DNS resolution with private IP rejection
    - Redirect re-validation against private IP ranges
    - Response body capped at 1MB (streaming read)
    """

    BLOCKED_NETWORKS = [
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
        ipaddress.ip_network("127.0.0.0/8"),
        ipaddress.ip_network("169.254.0.0/16"),
        ipaddress.ip_network("::1/128"),
        ipaddress.ip_network("fc00::/7"),
        ipaddress.ip_network("fe80::/10"),
    ]

    ALLOWED_SCHEMES = frozenset({"http", "https"})
    MAX_RESPONSE_BYTES = 1_048_576  # 1 MB
    MAX_REDIRECTS = 5
    TIMEOUT_SECONDS = 10.0
    CHUNK_SIZE = 64 * 1024  # 64 KB

    def __init__(
        self,
        *,
        resolver: DnsResolver | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        """Initialize the fetcher.

        Args:
            resolver: Optional DNS resolver callable for testing.
                      Signature matches socket.getaddrinfo.
                      If None, uses socket.getaddrinfo.
            transport: Optional httpx transport for testing.
                      If provided, the fetcher uses this transport instead of real network.
        """
        self._resolver: DnsResolver = resolver or socket.getaddrinfo
        self._transport = transport

    async def fetch(self, url: str) -> FetchResult:
        """Fetch URL content safely with streaming response body.

        Raises:
            SSRFError: On policy violation (private IP, bad scheme, too large, etc.)
            httpx.TimeoutException: On connection/read timeout.
        """
        self._validate_url(url)
        parsed = urlparse(url)
        self._resolve_and_validate_host(parsed.hostname or "")

        current_url = url
        redirects = 0

        client_kwargs: dict = {
            "timeout": self.TIMEOUT_SECONDS,
            "follow_redirects": False,
        }
        if self._transport:
            client_kwargs["transport"] = self._transport

        async with httpx.AsyncClient(**client_kwargs) as client:
            while True:
                response = await client.send(
                    client.build_request("GET", current_url),
                    stream=True,
                )

                if response.is_redirect:
                    await response.aclose()
                    redirects += 1
                    if redirects > self.MAX_REDIRECTS:
                        raise SSRFError("Too many redirects")

                    redirect_url = str(response.next_request.url) if response.next_request else ""
                    if not redirect_url:
                        location = response.headers.get("location", "")
                        redirect_url = location

                    self._validate_url(redirect_url)
                    redirect_parsed = urlparse(redirect_url)
                    self._resolve_and_validate_host(redirect_parsed.hostname or "")
                    current_url = redirect_url
                    continue

                # Stream-read the response body with size cap
                try:
                    content = await self._stream_response_with_cap(response)
                finally:
                    await response.aclose()

                break

        content_type = response.headers.get("content-type", "")

        return FetchResult(
            content=content,
            final_url=current_url,
            content_type=content_type,
        )

    def _validate_url(self, url: str) -> None:
        """Validate URL scheme and length.

        Raises:
            SSRFError: If scheme not allowed or URL too long.
        """
        if len(url) > 2048:
            raise SSRFError("URL too long")

        parsed = urlparse(url)
        scheme = parsed.scheme.lower()

        if scheme not in self.ALLOWED_SCHEMES:
            raise SSRFError(f"Scheme not allowed: {scheme}")

        if not parsed.hostname:
            raise SSRFError("URL has no hostname")

    def _resolve_and_validate_host(self, hostname: str) -> None:
        """DNS-resolve hostname and reject private IPs.

        Raises:
            SSRFError: If hostname resolves to a private/blocked IP.
        """
        try:
            addr_infos = self._resolver(hostname, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        except socket.gaierror as exc:
            raise SSRFError(f"DNS resolution failed for {hostname}: {exc}") from exc

        for addr_info in addr_infos:
            ip_str = addr_info[4][0]
            if self._is_private_ip(ip_str):
                raise SSRFError(f"Host resolves to private IP: {ip_str}")

    def _is_private_ip(self, ip_str: str) -> bool:
        """Check if an IP address falls within blocked ranges."""
        try:
            ip = ipaddress.ip_address(ip_str)
        except ValueError:
            return True  # Unparseable IPs are blocked

        return any(ip in network for network in self.BLOCKED_NETWORKS)

    async def _stream_response_with_cap(self, response: httpx.Response) -> bytes:
        """Stream response body with 1MB byte cap.

        Reads chunks incrementally: never buffers more than MAX_RESPONSE_BYTES.

        Raises:
            SSRFError: If response exceeds MAX_RESPONSE_BYTES.
        """
        chunks: list[bytes] = []
        total_bytes = 0

        async for chunk in response.aiter_bytes(chunk_size=self.CHUNK_SIZE):
            total_bytes += len(chunk)
            if total_bytes > self.MAX_RESPONSE_BYTES:
                raise SSRFError("Response exceeds 1MB")
            chunks.append(chunk)

        return b"".join(chunks)
