# master-control-program

The TRON joke, implemented with the **Model Context Protocol**.

A small personal sidecar to the official X MCP: let the robot see the picture,
and let it post the picture when explicitly asked. The server and OAuth login
are implemented in **Racket**. The superseded Python runtime has been removed;
Python is used only for optional, independent MCP client checks.

## Status

Implemented: local stdio MCP, original image retrieval, JPEG/PNG upload,
text/media/reply posting, and local OAuth 2.0 PKCE login. Writes are hidden and
disabled by default. No live uploads or posts have been made.

Verified on 2026-10-07: **33 Racket tests and 3 independent MCP client tests pass,
with zero skips**. A live X image passed through native Racket HTTPS, native
image validation, and stdio MCP with identical bytes to the original prototype.
The returned image was inspected visually during verification. OAuth callback
and exchange behavior is tested with synthetic data; live account authorization
and writes remain unverified. Hosted ChatGPT integration is still unfinished.

The connected official X MCP exposed reads and media URLs but no image-byte
retrieval, media upload, or post creation when last checked. Re-check that surface
before extending this sidecar. Personal content and credentials are not committed.

## Run

Requires Racket (tested with 9.3), its `draw-lib`, and native OpenSSL, Cairo,
JPEG/PNG and WebP libraries. Full Racket distributions include the Racket
libraries; Linux system packages provide the native libraries. No Python, Pillow,
MCP SDK, or additional Racket MCP package is needed to run the application.

```sh
racket racket/server.rkt
```

Configure a local MCP client to launch `racket` with the absolute path to
`racket/server.rkt` as its argument. Only `fetch_x_media` is exposed by default;
it needs no token. The image-validation worker resolves its own source path and
uses the same Racket executable, independently of the client's working directory.

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `fetch_x_media` | Direct HTTPS `pbs.twimg.com/media/` URL; optional post ID/media key | Original MCP image content, MIME, dimensions, size, provenance |
| `upload_x_media` | Raw base64 static JPEG/PNG, at most 5 MiB | Media ID, optional media key and expiry |
| `create_x_post` | Text and/or up to four image media IDs; optional reply ID | Post ID and URL |

Fetch accepts static JPEG, PNG, and WebP up to 5 MiB and 40 megapixels. These are
local limits, not claims about X account limits. Redirects, arbitrary hosts,
signed queries, GIFs, APNG containers, animated WebP, and videos are rejected.
Images are decoded for validation but the original bytes are returned unchanged.
There is no resize, recompression, media cache, or archive. A thumbnail URL
remains a thumbnail; select an original-size URL upstream when needed.

Reuse URLs from the official X MCP to avoid duplicate paid post lookups. Media
keys alone are unsupported. Optional provenance IDs are caller-provided, not
verified against X. Base64 upload is for clients that can supply bytes
programmatically; do not ask an LLM to transcribe image data. Convenient generated
image handoff for hosted ChatGPT remains to be designed and verified.

## Authentication and writes

1. Create/select an app in the [X Developer Console](https://developer.x.com/),
   enable OAuth 2.0, and register `http://127.0.0.1:8765/callback` exactly.
2. Set `X_CLIENT_ID` locally. Confidential apps also require `X_CLIENT_SECRET`.
   Use your local secret manager/environment; do not paste secrets into chat.
3. Run `racket racket/login.rkt` and open its authorization URL on this machine.
   Authorize your account and check the terminal for completion.
4. Start the server with `MCP_X_ENABLE_WRITES=1` to expose write tools.
   Live uploads/publishing must follow an explicit user request.

Login requests `tweet.read users.read tweet.write media.write`. Tokens are stored
atomically in `.secrets/x-token.json` with mode 0600, ignored by Git. Set
`MCP_X_TOKEN_FILE` to an absolute path when using a different working directory.
`X_ACCESS_TOKEN` can supply an existing user-context OAuth token instead.
An app-only bearer token is insufficient for writes.

No refresh flow or `offline.access` scope is implemented. Run login again on
expiry. The official hosted X MCP's credentials are not exposed to this sidecar;
separate authorization is required. The developer account needs API access and
any required credits.

Endpoints and scopes were checked on 2026-10-07 against X's
[OAuth PKCE reference](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code),
[upload reference](https://docs.x.com/x-api/media/upload-media), and
[post reference](https://docs.x.com/x-api/posts/create-post).

## Verification and architecture

```sh
raco test racket/tests.rkt racket/oauth-tests.rkt racket/lib-tests.rkt
```

Tests use synthetic fixtures. OAuth tests open localhost listeners; they never
contact X. Some sandboxes require permission for these local sockets.

Optional independent MCP client checks use Python 3.11+ and the locked SDK:

```sh
uv sync --locked
.venv/bin/python -m unittest discover -s tests -v
```

Python has no production entrypoints and Pillow is no longer a dependency.
The original prototype is available in Git history at `aaa39e4`; its observable
contracts are preserved in synthetic fixtures and cross-language tests.

See [Racket architecture and reusable modules](docs/racket.md) and
[verification details](docs/verification.md). No write automatically retries.
After a timeout, cancellation, or malformed response, check X before resubmitting:
a write may already have succeeded. Arbitrary upstream error bodies are suppressed.

An authenticated remote transport is still needed for hosted web clients.
Do not expose this local server through an unauthenticated HTTP wrapper.
