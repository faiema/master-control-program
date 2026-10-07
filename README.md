# master-control-program

The TRON joke, implemented with the **Model Context Protocol**.

A personal sidecar to the official X MCP: let the robot see the picture, and let
it post the picture when explicitly asked. **Racket is the standard language
target. This Python implementation is the initial prototype.**

## Status

Implemented: local stdio MCP adapter, original image retrieval, JPEG/PNG upload,
text/media/reply posting, and local OAuth 2.0 PKCE login. Writes are hidden and
disabled by default. No live uploads or posts have been made.

Verified on 2026-10-07: all 22 tests pass with zero skips, including a separate
stdio MCP process. A live X image was returned as MCP image content, decoded by
the client, and visually inspected through the local image viewer. Live OAuth
and writes remain unverified. This is a prototype, not a completed ChatGPT web
integration.

The connected official X-MCP successfully returned account and recent-post data.
Its exposed tools had no image-byte retrieval, media upload, or post creation.
Re-check that surface before extending this workaround. Personal post contents
and credentials are not stored here.

## Install

Requires Python 3.11+ and network access:

```sh
uv sync --locked
.venv/bin/master-control-program
```

The process speaks MCP on stdin/stdout. Configure a local MCP client to launch the
absolute path to `.venv/bin/master-control-program` with this directory as its
working directory. Only `fetch_x_media` is exposed by default; it needs no token.

The prototype bounds the SDK to the documented v1 FastMCP API. SDK v2 migration
should be evaluated alongside the Racket transport. The checked-in `uv.lock` resolves MCP 1.30.0 and Pillow 12.3.0;
use `uv sync --locked` to reproduce the environment.

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `fetch_x_media` | Direct HTTPS `pbs.twimg.com/media/` URL; optional post ID/media key | Original MCP **image content**, MIME, dimensions, size, provenance |
| `upload_x_media` | Raw base64 static JPEG/PNG, at most 5 MiB | Media ID, optional media key and expiry |
| `create_x_post` | Text and/or up to four image media IDs; optional reply ID | Post ID and URL |

Fetch accepts static JPEG, PNG, and WebP up to 5 MiB and 40 megapixels. These are
local limits, not claims about X account limits. Redirects, arbitrary hosts,
signed queries, GIFs, animations, and videos are rejected. Images are not resized
or recompressed. A thumbnail URL remains a thumbnail; select an original-size URL
upstream when needed. There is no media cache or archive.

Reuse the URL from the official X MCP to avoid a second paid post lookup. Media
keys alone are unsupported. Optional provenance IDs are caller-provided, not
verified against X.

Base64 upload is for clients that can supply bytes programmatically. Do not ask an
LLM to transcribe large base64 blobs. Convenient generated-image/file handoff in
ChatGPT web remains to be designed and empirically verified.

## Authentication and writes

1. Create/select an app in the [X Developer Console](https://developer.x.com/),
   enable OAuth 2.0, and register `http://127.0.0.1:8765/callback` exactly.
2. Set `X_CLIENT_ID` locally. Confidential apps also require `X_CLIENT_SECRET`.
   Use your local secret manager/environment; do not paste secrets into chat.
3. Run `.venv/bin/mcp-x-login` and open its authorization URL in a browser on this
   machine. Authorize your account.
4. Start the MCP server with `MCP_X_ENABLE_WRITES=1` to expose write tools.
   Live uploads/publishing must follow an explicit user request.

Login requests `tweet.read users.read tweet.write media.write`. Tokens are stored
in `.secrets/x-token.json` with mode 0600, ignored by Git. Set `MCP_X_TOKEN_FILE`
to an absolute path if the MCP client uses another working directory.
`X_ACCESS_TOKEN` can supply an existing **user-context** OAuth token instead.
An app-only bearer token is insufficient for writes.

There is no refresh flow or `offline.access` scope yet. Run login again on expiry.
The official hosted X MCP's credentials are not exposed to this sidecar; separate
authorization is required. The X developer account needs API access and any
required credits.

Endpoints and scopes were checked on 2026-10-07 against X's
[OAuth PKCE reference](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code),
[upload reference](https://docs.x.com/x-api/media/upload-media), and
[post reference](https://docs.x.com/x-api/posts/create-post).
Live compatibility remains unverified.

## Tests and architecture

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests mock network operations and never publish. Core tests can also run using
`python3 -m unittest discover -s tests -v` when system Python has Pillow.
After installation, require **zero skips**; then complete the
[real-client verification](docs/verification.md).

`media.py` validates bytes, `http.py` bounds requests, `auth.py` owns credentials,
`x_api.py` constructs writes, `tools.py` constructs MCP content, and `server.py`
adapts the SDK. These boundaries and tests should guide the Racket implementation.

No write automatically retries. Timeouts or malformed responses can follow a
successful write: check X before submitting again. HTTP status codes are retained;
arbitrary error bodies are suppressed to avoid credential reflection. Richer safe
X error normalization remains future work.

An authenticated remote transport is still needed for a hosted web client.
Do not expose this local prototype through an unauthenticated HTTP wrapper.
