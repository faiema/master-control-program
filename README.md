# master-control-program

The TRON joke, implemented with the **Model Context Protocol**.

A small personal sidecar to the official X and GitHub MCPs: let the robot see the picture,
and let it post the picture when explicitly asked. The server and OAuth login
are implemented in **Racket**. The superseded Python runtime has been removed;
Python is used only for optional, independent MCP client checks.

## Status and scope

Personal, self-hosted software: **one owner and one X account per instance**.
Keep access restricted to that owner. There is no multi-user authentication or
account isolation. Enabling writes allows connected clients to act on the
configured X account; live posting still requires explicit user authorization.

Implemented: local stdio MCP, original image retrieval, JPEG/PNG upload,
text/media/reply posting, and local OAuth 2.0 PKCE login. Writes are hidden and
disabled by default. Live OAuth, image upload, a post, and an image reply succeeded
from local clients on 2026-10-08. Hosted ChatGPT publishing remains unverified.

Verified on 2026-10-10: **74 Racket tests and 9 Python tests pass,
with zero skips**. A live X image passed through native Racket HTTPS, native
image validation, and stdio MCP with identical bytes to the original prototype.
The returned image was inspected visually during verification. Ordinary OAuth
and write tests use synthetic data and never publish real content.

ChatGPT file references are now supported behind an opt-in setting, with a
read-only image round-trip tool and file input for uploads. See
[ChatGPT connection and acceptance checks](docs/chatgpt.md). Secure MCP Tunnel
reported healthy/ready during setup; ChatGPT successfully discovered both
read-only tools, and the user confirmed it sees and describes a real X image
returned by `fetch_x_media`. The user also confirmed an accessible generated
image passes through `inspect_chatgpt_image` and returns visible image content.
The tunnel is currently a local test runtime, not a boot-persistent deployment.
A [sample systemd service](docs/deployment.md) is provided for deployment after launch.
GitHub image retrieval passed live public and private canonical-image checks;
the user also confirmed hosted ChatGPT upload, fetch-back, and visual inspection. See [GitHub setup](docs/github.md).
See the [release checklist and backlog](docs/release.md) for launch gates.

The connected official X MCP exposed reads and media URLs but no image-byte
retrieval, media upload, or post creation when last checked. Re-check that surface
before extending this sidecar. Personal content and credentials are not committed.

## Installation for Bakas (by Faie)

1. Point ChatGPT at this repo.
2. Explain what you want to make happen.
3. Do what he tells you.

## Run

Requires Racket (tested with 9.3), its `draw-lib`, and native OpenSSL, Cairo,
JPEG/PNG and WebP libraries. Full Racket distributions include the Racket
libraries; Linux system packages provide the native libraries. No Python, Pillow,
MCP SDK, or additional Racket MCP package is needed to run the application.

```sh
racket racket/server.rkt
```

Configure a local MCP client to launch `racket` with the absolute path to
`racket/server.rkt` as its argument. `fetch_x_media`, `fetch_github_image`, and `fetch_github_text` are exposed by default;
public image reads need no token. Private GitHub access uses separate
[GitHub credentials](docs/github.md). The image-validation worker resolves its own source path and
uses the same Racket executable, independently of the client's working directory.

## Tools

Self-hosted Git on faie.net is available through `git_repository`: file/image
reads, history, diffs, fetch, staged edits, commits, branches, checkout, merges
and normal pushes. Configure an explicit repository allowlist and separate Git
credentials; writes require `MCP_GIT_ENABLE_WRITES=1`. See [Git setup](docs/git.md).

| Tool | Input | Result |
| --- | --- | --- |
| `fetch_x_media` | Direct HTTPS `pbs.twimg.com/media/` URL; optional post ID/media key | Original MCP image content, MIME, dimensions, size, provenance |
| `fetch_github_image` | GitHub repository, file path, optional ref | Original MCP image content and verified blob SHA provenance |
| `fetch_github_text` | GitHub repository, text path, optional ref | Exact UTF-8 text and verified blob SHA |
| `upload_github_text` (GitHub writes enabled) | Repository, path, branch, message, content; optional expected SHA and idempotency key | Verified commit receipt or structured conflict/uncertainty |
| `patch_github_text` (GitHub writes enabled) | Repository, path, branch, expected SHA, message, literal edit; optional idempotency key | Verified exact append, replacement, or insertion |
| `upload_github_image` (GitHub writes enabled) | Repository, path, branch, message; image bytes/file; optional expected blob SHA | Commit SHA, verified blob SHA and file URL |
| `inspect_chatgpt_image` (opt-in) | ChatGPT file reference from an explicitly allowed host | Original MCP image content and metadata |
| `upload_x_media` (writes enabled) | Raw base64 static JPEG/PNG or, with file inputs enabled, a ChatGPT file reference; at most 5 MiB | Media ID, optional media key and expiry |
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
image handoff for hosted ChatGPT uses the optional file-reference input described
in [docs/chatgpt.md](docs/chatgpt.md). This path has been verified with an accessible
generated image; a failed generation with no accessible file cannot be passed.

GitHub image and text uploads create a real commit and require `MCP_GITHUB_ENABLE_WRITES=1`
plus a token with Contents: write. They create only by default; replacement
requires the current blob SHA. Text writes support verified receipts and optional
persistent idempotency via `MCP_GITHUB_TEXT_STATE_DIR`; see [text setup](docs/github.md#utf-8-text-files).
See [GitHub upload setup](docs/github.md#upload-an-image-to-a-repository).

## Authentication and writes

1. Create/select an app in the [X Developer Console](https://developer.x.com/),
   enable OAuth 2.0, and register `http://127.0.0.1:8765/callback` exactly.
2. Set `X_CLIENT_ID` locally. Confidential apps also require `X_CLIENT_SECRET`.
   Use your local secret manager/environment; do not paste secrets into chat.
3. Run `racket racket/login.rkt` and open its authorization URL on this machine.
   Authorize your account and check the terminal for completion.
4. Start the server with `MCP_X_ENABLE_WRITES=1` to expose write tools.
   Live uploads/publishing must follow an explicit user request.

Login requests `tweet.read users.read tweet.write media.write offline.access`. Tokens are stored
atomically in `.secrets/x-token.json` with mode 0600, ignored by Git. Set
`MCP_X_TOKEN_FILE` to an absolute path when using a different working directory.
`X_ACCESS_TOKEN` can supply an existing user-context OAuth token instead; this
override bypasses the saved token and cannot refresh automatically.
An app-only bearer token is insufficient for writes.

Before authenticated requests, saved tokens refresh automatically when expired
or within 30 seconds of expiry. Refresh tokens rotate in the same private file,
under a lock shared by local processes. No background timer is needed. The saved
record includes the client ID; confidential apps must also keep `X_CLIENT_SECRET`
available in the server environment. The client secret is never saved in the
record. A busy lock returns a retryable error; failed refresh never sends the
pending upload/post, and uncertain writes are never automatically retried.

**Existing installations need one new login** to grant `offline.access`, then a
restart of the server/tunnel process to load this implementation. Revoked or
invalid refresh credentials require login again. Network failures preserve the
saved file; if X rotated a token but its response or local save was lost, a new
login may be necessary. Do not share one token across separate machines or copy
it between active installations: locking only coordinates the same local file.
This follows [X's OAuth refresh flow](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code).

The official hosted X MCP's credentials are not exposed to this sidecar;
separate authorization is required. The developer account needs API access and
any required credits.

For a local write-enabled process using the saved token:

```sh
env -u X_ACCESS_TOKEN MCP_X_ENABLE_WRITES=1 \
  MCP_X_TOKEN_FILE=/absolute/repo/.secrets/x-token.json \
  racket /absolute/repo/racket/server.rkt
```

This enables tools; it does not publish by itself. ChatGPT file inputs add
separate settings described in [ChatGPT setup](docs/chatgpt.md).

Endpoints and scopes were checked on 2026-10-07 against X's
[OAuth PKCE reference](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code),
[upload reference](https://docs.x.com/x-api/media/upload-media), and
[post reference](https://docs.x.com/x-api/posts/create-post).

## Verification and architecture

```sh
raco test racket/tests.rkt racket/oauth-tests.rkt racket/lib-tests.rkt
raco test racket/chatgpt-file-tests.rkt racket/cancellation-tests.rkt racket/github-tests.rkt racket/github-upload-tests.rkt racket/github-text-tests.rkt
```

Tests use synthetic fixtures. OAuth tests open localhost listeners; they never
contact X. Some sandboxes require permission for these local sockets.

The combined development/release check uses Python 3.11+ and the locked MCP SDK:

```sh
uv sync --locked
bash scripts/check
```

This runs both suites and fails on skipped tests or empty Python discovery.
[Hosted CI](https://github.com/faiema/master-control-program/actions/runs/37883581680)
passed the same command on Ubuntu 24.04 with Racket 9.3 and Python 3.13. Other Racket versions and
Windows remain unverified. Both suites are required for development/release
checks; Python remains optional for users running the server.

Python has no production entrypoints and Pillow is no longer a dependency.
The original prototype is available in Git history at `aaa39e4`; its observable
contracts are preserved in synthetic fixtures and cross-language tests.

See [Racket architecture and reusable modules](docs/racket.md) and
[verification details](docs/verification.md). No write automatically retries.
After a timeout, cancellation, or malformed response, check X before resubmitting:
a write may already have succeeded. Errors identify the operation and HTTP status,
translate recognized X problem types and OAuth error names, and retain bounded
numeric X error codes. Free-form upstream titles, details, messages, URLs, and
request IDs are suppressed. Error bodies are read up to 16 KiB; malformed or
oversized bodies still yield status-based advice. Up to four nested errors are
summarized, including partial errors in successful HTTP responses.

For rate limits and service failures, validated integer `Retry-After` seconds and
`x-rate-limit-reset` timestamps provide a suggested wait (the longer valid value).
Invalid, past reset, or more-than-seven-day values are omitted. HTTP-date
`Retry-After` values are not interpreted. Timing is advice, never an automatic
retry; usage caps may require credits or account changes instead of waiting.

MCP cancellation is supported while tools run. The transport handles up to eight
active tool calls, responds to pings, and processes `notifications/cancelled`.
Responses can arrive out of order and are matched by request ID. Cancellation
before the upload/post boundary stops the request and releases its resources;
no response is sent for the cancelled request. Unknown, completed, malformed,
and initialization cancellation notifications are ignored.

A cancellation during token refresh is deferred until the credential transaction
and lock release finish, then stops before upload/post submission. Once a write
crosses the submission boundary, cancellation is ignored and its bounded request
finishes normally. It may succeed; a timeout or other uncertain outcome still
requires checking X before retrying. Cancellation cannot undo a published post.
Diagnostics distinguish these cases without echoing client-provided reasons.
A client may discard a late response after cancellation. End-of-input drains
accepted requests; process termination cannot guarantee their remote outcomes.

For hosted web clients, use the [Secure MCP Tunnel setup](docs/chatgpt.md).
Do not expose this local server through an unauthenticated HTTP wrapper.

## License

Copyright (C) 2026 Faië 魔法.

GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). See
[LICENSE](LICENSE) for the full terms. This applies to this repository's original
source, documentation, and synthetic fixtures. Dependencies retain their own
licenses. This software comes without warranty.
