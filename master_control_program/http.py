"""Bounded HTTP with no redirects, retries, cookies, or credential logging."""
import json
import socket
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener


class BridgeError(Exception):
    """Safe to show to an MCP client."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, *, method="GET", headers=None, body=None, limit=8 * 1024 * 1024):
    # The X image CDN rejected urllib's default UA in live verification.
    # Identify this client explicitly; do not impersonate a browser.
    req = Request(url, data=body, headers={"User-Agent": "master-control-program/0.1", **(headers or {})}, method=method)
    try:
        with build_opener(NoRedirect).open(req, timeout=30) as response:
            data = response.read(limit + 1)
            if len(data) > limit:
                raise BridgeError("HTTP: response exceeds the local size limit; use a smaller image.")
            return dict(response.headers), data
    except HTTPError as error:
        # Never echo arbitrary upstream bodies, URLs, or authorization headers.
        advice = {
            401: "Authenticate again with mcp-x-login.",
            403: "Check your app permissions, granted scopes, and account access.",
            429: "Rate limited; wait before retrying.",
        }.get(error.code, "Check the endpoint and account access.")
        raise BridgeError(f"HTTP {error.code}: {advice} Writes are not retried; check X before resubmitting.") from None
    except (URLError, TimeoutError, socket.timeout, OSError):
        raise BridgeError("HTTP: connection failed or timed out. Check connectivity. A write may have succeeded; check X before resubmitting.") from None


def json_request(url, *, method="GET", headers=None, payload=None, transport=request):
    headers = dict(headers or {})
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    _, raw = transport(url, method=method, headers=headers, body=body, limit=1024 * 1024)
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError):
        raise BridgeError("X API: invalid JSON response; check for an API outage.") from None
    if not isinstance(value, dict):
        raise BridgeError("X API: expected a JSON object; response schema changed.")
    if value.get("errors"):
        raise BridgeError("X API: response contains errors or partial results; operation was not accepted as complete. Check account access before retrying.")
    return value
