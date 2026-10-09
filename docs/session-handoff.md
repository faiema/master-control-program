# Session handoff — 2026-10-08

## Current direction

Prepare a public source release for personal, self-hosted use: one owner and one
X account per instance. The user selected GNU Affero GPL; the release uses
AGPL-3.0-only. Shared public hosting is outside the release scope. Follow the
[release checklist](release.md), which owns the current TODOs and launch gates.

Token refresh is implemented and live-verified; replacement tokens are saved
and the restarted tunnel has its confidential-client credentials. The user accepted cancellation as a TODO, deferred stronger
decoder isolation while access remains private, and required improved safe X
error reporting before launch; that implementation is now complete with synthetic
coverage of HTTP and OAuth failures, timing, redaction, and partial errors. Complete release preparation before the next
hosted ChatGPT publishing test. Do not publish test posts without explicit
content authorization. Publishing the repository/tag is a separate action.

## Runtime and verification

- Production runtime and OAuth login are native Racket. Python is only an
  independent test client. Do not restart the completed language migration.
- Local Linux/Racket 9.3 checks pass: 46 Racket cases and 5 Python
  cases, zero skips. Run `uv sync --locked` then `bash scripts/check`.
- ChatGPT discovered read tools through Secure MCP Tunnel after the repeated
  initialization fix, and the user confirmed visual inspection of both an X
  image and an accessible generated image. See [verification](verification.md).
- Live OAuth, upload and posting succeeded through a local Python MCP client.
  An image reply then succeeded through a local Racket client invoking tool
  handlers. The user confirmed the reply worked. Hosted ChatGPT publishing has
  not been exercised; do not conflate these paths.
- Generated images, prompts and non-secret posting receipts are local output
  under ignored `output/`. They are not source-release assets.

## Local tunnel notes

The test client is v0.0.16, checksum-verified, currently installed under
`/tmp/mcp-tunnel-client/`. Profiles and credentials are under ignored `.secrets/`.
The managed alias is `master-control-program`. Use the client's `runtimes status`
to discover current health and UI endpoints rather than relying on old ports.
Do not print full runtime logs or signed image URLs.

The current setup uses ignored `.secrets/serve-chatgpt` to load the private
`.secrets/x-client.env` and launch `racket/server.rkt`, with writes and
ChatGPT files enabled, an absolute token-file path, and `X_ACCESS_TOKEN` unset.
Only the exact observed image-storage host is allowed. Preserve
`MCP_STDIO_SEND_INITIALIZED_NOTIFICATION=true` when restarting the tunnel. The
readonly launcher intentionally forces writes off and is not the posting entrypoint.
The user completed the new offline-access login; the saved confidential-client
grant includes a refresh token. Live refresh and rotation succeeded, and the restarted Racket child has
X_CLIENT_SECRET available; health and readiness were verified. Neither old health reports nor
past successful posts establish that credentials are still valid.

The user proposed an always-on Debian server as the eventual deployment target.
It was inspected read-only; nothing was installed. Deployment and any OS upgrade
are separate work. One service can supervise tunnel-client and its Racket child.

## Architecture boundaries

Keep generic code in `racket/lib/` free of X policy. Preserve synthetic contracts
and independent client tests. The image worker has an empty environment and
timeout/crash isolation, but is not an OS security sandbox; it retains the
service user's permissions. Do not claim it cannot access credential files.

Read `AGENTS.md`, `README.md`, `docs/racket.md`, `docs/chatgpt.md`, and
`docs/release.md` before changing authentication, transport, or file handoff.
