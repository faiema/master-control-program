"""Local OAuth PKCE login. Credentials never appear in MCP results."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import secrets
import time
from urllib.parse import parse_qs, urlencode, urlsplit

from .http import BridgeError, request

REDIRECT_URI = "http://127.0.0.1:8765/callback"
SCOPES = "tweet.read users.read tweet.write media.write"


def token_path():
    return Path(os.environ.get("MCP_X_TOKEN_FILE", ".secrets/x-token.json"))


def access_token():
    token = os.environ.get("X_ACCESS_TOKEN")
    if token:
        return token
    try:
        path = token_path()
        if path.stat().st_mode & 0o077:
            raise BridgeError("Authentication: token file permissions must be 0600.")
        record = json.loads(path.read_text())
        token = record["access_token"]
        if not isinstance(token, str) or not token or record["expires_at"] <= time.time() + 30:
            raise ValueError()
        return token
    except (OSError, ValueError, KeyError, TypeError):
        raise BridgeError("Authentication: token missing, invalid, or expired. Run mcp-x-login locally.") from None


def authorization(client_id):
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    url = "https://x.com/i/oauth2/authorize?" + urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": REDIRECT_URI,
        "scope": SCOPES, "state": state, "code_challenge": challenge,
        "code_challenge_method": "S256"})
    return url, state, verifier


def exchange(code, verifier, client_id, client_secret=None, *, transport=request):
    body = {"grant_type": "authorization_code", "code": code,
            "redirect_uri": REDIRECT_URI, "code_verifier": verifier, "client_id": client_id}
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if client_secret:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    _, raw = transport("https://api.x.com/2/oauth2/token", method="POST", headers=headers,
                       body=urlencode(body).encode(), limit=64 * 1024)
    try:
        result = json.loads(raw)
        token, lifetime = result["access_token"], result["expires_in"]
        if (not isinstance(token, str) or not token or not isinstance(lifetime, (int, float))
                or lifetime <= 0 or result.get("token_type", "").lower() != "bearer"
                or not set(SCOPES.split()).issubset(set(result["scope"].split()))):
            raise ValueError()
        return {"access_token": token, "expires_at": time.time() + lifetime}
    except (ValueError, KeyError, TypeError, AttributeError):
        raise BridgeError("Authentication: token exchange returned invalid data or missing scopes; check app settings.") from None


def save_token(record, path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + secrets.token_hex(8) + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def login():
    client_id = os.environ.get("X_CLIENT_ID")
    if not client_id:
        raise BridgeError("Authentication: set X_CLIENT_ID from your X developer app first.")
    url, state, verifier = authorization(client_id)
    completed = False
    failure = None

    class Callback(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Request URLs contain short-lived authorization codes.

        def do_GET(self):
            nonlocal completed, failure
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            if (parsed.path != "/callback" or query.get("state") != [state]
                    or len(query.get("code", [])) != 1):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"Invalid callback. Retry login if access was denied.")
                return
            try:
                record = exchange(query["code"][0], verifier, client_id, os.environ.get("X_CLIENT_SECRET"))
                save_token(record, token_path())
                message = b"Authenticated. You can close this tab."
                status = 200
            except (BridgeError, OSError) as error:
                failure = error
                message = b"Authentication failed. Check the local terminal."
                status = 400
            completed = True
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(message)

    with HTTPServer(("127.0.0.1", 8765), Callback) as server:
        server.timeout = 1
        print("Open this URL in a browser on this machine:\n" + url)
        deadline = time.monotonic() + 300
        while not completed and time.monotonic() < deadline:
            server.handle_request()
    if failure:
        raise BridgeError("Authentication: login or token storage failed; check app settings and local file permissions.")
    if not completed:
        raise BridgeError("Authentication: login timed out; run login again.")
    print("Token stored with owner-only permissions. Re-run login when it expires.")


def main():
    try:
        login()
    except (BridgeError, OSError) as error:
        raise SystemExit(str(error)) from None


if __name__ == "__main__":
    main()
