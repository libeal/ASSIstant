#!/usr/bin/env python3
"""DNS-pinned HTTP helpers shared by provider and controlled downloads."""

from __future__ import annotations

import http.client
import ipaddress
import socket
import ssl
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable
from urllib.parse import urljoin, urlsplit


REDIRECT_STATUS_CODES = frozenset({301, 302, 303, 307, 308})
SENSITIVE_REDIRECT_HEADERS = frozenset(
    {
        "api-subscription-key",
        "authorization",
        "cookie",
        "cookie2",
        "proxy-authorization",
        "x-api-key",
    }
)


class PinnedHTTPPolicyError(ValueError):
    """A URL or one of its DNS answers violates the outbound policy."""

    def __init__(self, code: str, message: str, *, url: str = "", address: str = ""):
        super().__init__(message)
        self.code = code
        self.url = url
        self.address = address


def _pinned_socket(addresses: Iterable[str], port: int, timeout: float | None):
    last_error = None
    for address in addresses:
        try:
            return socket.create_connection((address, port), timeout=timeout)
        except OSError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    raise OSError("hostname did not resolve to a usable address")


class PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, *args, resolved_addresses=None, **kwargs):
        super().__init__(host, *args, **kwargs)
        self.resolved_addresses = tuple(resolved_addresses or ())

    def connect(self):
        self.sock = _pinned_socket(self.resolved_addresses, self.port, self.timeout)
        if self._tunnel_host:
            self._tunnel()


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *args, resolved_addresses=None, **kwargs):
        super().__init__(host, *args, **kwargs)
        self.resolved_addresses = tuple(resolved_addresses or ())

    def connect(self):
        self.sock = _pinned_socket(self.resolved_addresses, self.port, self.timeout)
        if self._tunnel_host:
            self._tunnel()
        # HTTPConnection normalizes self.host without the port. Keeping it here
        # preserves the original hostname for certificate validation and SNI.
        server_hostname = self._tunnel_host or self.host
        self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)


class PinnedHTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, resolved_addresses):
        super().__init__()
        self.resolved_addresses = tuple(resolved_addresses)

    def http_open(self, request):
        addresses = self.resolved_addresses

        class Connection(PinnedHTTPConnection):
            def __init__(self, host, *args, **kwargs):
                super().__init__(host, *args, resolved_addresses=addresses, **kwargs)

        return self.do_open(Connection, request)


class PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, resolved_addresses, *, context=None):
        super().__init__(context=context)
        self.resolved_addresses = tuple(resolved_addresses)

    def https_open(self, request):
        addresses = self.resolved_addresses

        class Connection(PinnedHTTPSConnection):
            def __init__(self, host, *args, **kwargs):
                super().__init__(host, *args, resolved_addresses=addresses, **kwargs)

        return self.do_open(Connection, request, context=self._context)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def resolve_public_https_url(
    url: str,
    *,
    resolver: Callable[..., list[tuple]] = socket.getaddrinfo,
) -> tuple[str, tuple[str, ...]]:
    """Validate an HTTPS URL and return all of its current public addresses."""

    if not isinstance(url, str) or not url or len(url) > 8192:
        raise PinnedHTTPPolicyError("unsafe_url", "URL is missing or too long", url=str(url or ""))
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in url):
        raise PinnedHTTPPolicyError("unsafe_url", "URL contains control characters", url=url)
    try:
        parsed = urlsplit(url)
        port = parsed.port or 443
    except ValueError as exc:
        raise PinnedHTTPPolicyError("unsafe_url", "URL authority is invalid", url=url) from exc
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise PinnedHTTPPolicyError(
            "unsafe_url",
            "only credential-free HTTPS URLs are allowed",
            url=url,
        )
    if not 1 <= port <= 65535:
        raise PinnedHTTPPolicyError("unsafe_url", "URL port is invalid", url=url)

    hostname = parsed.hostname
    try:
        answers = resolver(hostname, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise PinnedHTTPPolicyError("dns_error", str(exc), url=url) from exc
    addresses = []
    for answer in answers:
        try:
            address = str(answer[4][0])
            parsed_address = ipaddress.ip_address(address)
        except (IndexError, TypeError, ValueError) as exc:
            raise PinnedHTTPPolicyError("dns_error", "DNS returned an invalid address", url=url) from exc
        if not parsed_address.is_global:
            raise PinnedHTTPPolicyError(
                "unsafe_address",
                "resolved address is not public/global",
                url=url,
                address=address,
            )
        addresses.append(address)
    unique_addresses = tuple(sorted(set(addresses)))
    if not unique_addresses:
        raise PinnedHTTPPolicyError("dns_error", "hostname returned no usable addresses", url=url)
    return url, unique_addresses


def build_pinned_opener(addresses, *, context: ssl.SSLContext | None = None):
    """Build a proxy-free opener whose transport can only use given addresses."""

    return urllib.request.build_opener(
        NoRedirectHandler(),
        urllib.request.ProxyHandler({}),
        PinnedHTTPHandler(addresses),
        PinnedHTTPSHandler(addresses, context=context),
    )


def _url_origin(url: str) -> tuple[str, str, int] | None:
    """Return a normalized origin, or ``None`` for an invalid authority."""

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        return None
    scheme = parsed.scheme.lower()
    hostname = (parsed.hostname or "").lower()
    if not scheme or not hostname:
        return None
    if port is None:
        port = 443 if scheme == "https" else 80 if scheme == "http" else -1
    return scheme, hostname, port


def _headers_after_redirect(
    headers: dict[str, str],
    source_url: str,
    target_url: str,
) -> dict[str, str]:
    if _url_origin(source_url) == _url_origin(target_url):
        return headers
    return {
        name: value
        for name, value in headers.items()
        if name.lower() not in SENSITIVE_REDIRECT_HEADERS
    }


def open_validated_url(
    url: str,
    *,
    validate_url: Callable[[str], tuple[str, Iterable[str]]],
    headers: dict[str, str] | None = None,
    timeout: float = 30.0,
    max_redirects: int = 5,
    context: ssl.SSLContext | None = None,
):
    """Open an HTTP(S) URL after validating and pinning every redirect hop.

    ``validate_url`` owns the application-specific URL policy.  It must return
    the canonical URL and the numeric addresses allowed for that hop, or raise
    :class:`PinnedHTTPPolicyError`.  Keeping policy outside this transport
    helper lets callers enforce trusted-host and credential rules in addition to
    the generic pinned socket behavior.
    """

    if not callable(validate_url):
        raise TypeError("validate_url must be callable")
    if isinstance(max_redirects, bool) or not isinstance(max_redirects, int):
        raise ValueError("max_redirects must be an integer")
    if not 0 <= max_redirects <= 20:
        raise ValueError("max_redirects is outside the allowed range")

    current_url = str(url or "")
    request_headers = dict(headers or {})
    chain: list[str] = []
    seen: set[str] = set()
    for redirect_count in range(max_redirects + 1):
        checked_url, addresses = validate_url(current_url)
        checked_url = str(checked_url or "")
        if not checked_url:
            raise PinnedHTTPPolicyError(
                "unsafe_url",
                "URL validation returned an empty URL",
                url=current_url,
            )
        if checked_url in seen:
            raise PinnedHTTPPolicyError(
                "redirect_loop",
                "redirect loop detected",
                url=checked_url,
            )
        pinned_addresses = tuple(str(address) for address in (addresses or ()))
        if not pinned_addresses:
            raise PinnedHTTPPolicyError(
                "dns_error",
                "URL validation returned no usable addresses",
                url=checked_url,
            )
        seen.add(checked_url)
        chain.append(checked_url)
        opener = build_pinned_opener(pinned_addresses, context=context)
        request = urllib.request.Request(checked_url, headers=request_headers, method="GET")
        try:
            response = opener.open(request, timeout=timeout)
        except urllib.error.HTTPError as exc:
            if exc.code not in REDIRECT_STATUS_CODES:
                raise
            location = exc.headers.get("Location", "")
            exc.close()
            if not location:
                raise PinnedHTTPPolicyError(
                    "unsafe_redirect",
                    "redirect response did not provide a Location header",
                    url=checked_url,
                )
            if redirect_count >= max_redirects:
                raise PinnedHTTPPolicyError(
                    "too_many_redirects",
                    "redirect limit exceeded",
                    url=checked_url,
                )
            next_url = urljoin(checked_url, location)
            request_headers = _headers_after_redirect(
                request_headers,
                checked_url,
                next_url,
            )
            current_url = next_url
            continue
        return response, checked_url, pinned_addresses, tuple(chain)
    raise PinnedHTTPPolicyError(
        "too_many_redirects",
        "redirect limit exceeded",
        url=current_url,
    )


def open_public_https(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 30.0,
    max_redirects: int = 5,
    resolver: Callable[..., list[tuple]] = socket.getaddrinfo,
    context: ssl.SSLContext | None = None,
):
    """Open a public HTTPS URL, revalidating and pinning every redirect hop.

    The caller owns and must close the returned response. The other return
    values are the final URL, its pinned addresses, and the complete URL chain.
    """

    return open_validated_url(
        url,
        validate_url=lambda candidate: resolve_public_https_url(candidate, resolver=resolver),
        headers=headers,
        timeout=timeout,
        max_redirects=max_redirects,
        context=context,
    )
