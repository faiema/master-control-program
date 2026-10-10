# Verification and next steps

## Current summary — 2026-10-10

The latest checks passed 64 Racket cases and 6 Python tests (including independent
MCP client tests and cross-process token refresh);
all passed, with no skips. Live OAuth, upload, posting, and an image reply have
succeeded from local clients. Hosted ChatGPT image retrieval/inspection is
confirmed; hosted publishing and a manually attached image remain unverified.
Use the [release checklist](release.md) for current launch gates and follow-up.
Earlier observations below describe their dated test sessions, not current
limitations unless repeated in this summary or the checklist.

## ChatGPT file-input follow-up — 2026-10-07

- The expanded suite passes 40 Racket cases and 4 independent MCP client tests.
- Synthetic ChatGPT file objects pass through the real Racket stdio process and
  Python MCP SDK, returning unchanged image blocks and the original upload result
  contract. Tests check schema metadata, host rejection, MIME/size validation,
  signed-URL redaction, mutually exclusive inputs, and write gating.
- The read-only launch script overrides inherited write enablement and exposes
  only fetch and image inspection tools.
- The user confirmed Tunnel is available. The official tunnel-client v0.0.16
  Linux archive was downloaded and checked against the release SHA-256 list.
  A local read-only profile passed `doctor`; the managed runtime subsequently
  reported running, healthy, and ready. ChatGPT discovery succeeded after the
  handshake fix below. The user then confirmed ChatGPT sees and describes the
  real X image returned by `fetch_x_media`. The user also confirmed an accessible
  generated image passed to `inspect_chatgpt_image` returns visible image content.
  The storage hostname was observed, checked over HTTPS, and allowed exactly;
  no signed URL was copied into chat or documentation. See
  [ChatGPT setup](chatgpt.md). This is user-confirmed hosted behavior; the agent
  did not independently view that separate ChatGPT conversation.
- Rechecked the installed official X tool catalog; the three capability gaps
  remain. No paid account read, upload, or post was needed for these checks.
- Initial ChatGPT setup reached the server but failed. Tunnel health recorded
  two initialization epochs in the same stdio child. The server now returns
  metadata for repeated initialization without resetting readiness; regression
  tests preserve the initial handshake gate. After restart the user confirmed
  connection, and `/health/mcp` reported successful initialization and discovery
  of `fetch_x_media` and `inspect_chatgpt_image` in the same child at epoch 2.

## Observed on 2026-10-07

- The official X MCP returned account/post metadata and image URLs but exposed no
  image-byte retrieval, upload, or post creation tool when last checked.
- **33 Racket test cases and 3 independent Python MCP client tests pass**, with no
  skips. Native tests cover media formats and failures, URL validation, HTTP/API
  errors, write gating, request construction, token storage, OAuth PKCE and actual
  local callbacks, and generic MCP transport behavior.
- The production server and OAuth command no longer use Python. Pillow and the
  Python server entrypoints have been removed from the environment and source.
- Cross-language tests exercise a real Racket stdio process through MCP SDK 1.30.0.
  Fixture results match the original Python prototype's saved contracts.
- Live native Racket HTTPS and image validation returned a 1200 × 900 JPEG,
  279708 bytes, with SHA-256
  `503ca2a2783fcd5195fec87e181e3dad517b556b5bc61cae7451edc06e16765d`.
  Those bytes match the previously visually inspected image of a fairy and a
  gremlin beside monitors describing a failed image pipeline. This verifies
  the local path, not hosted ChatGPT rendering.
- The supplied URL's rendition was smaller than X metadata reported; no local
  resizing occurred. Use an original-size URL when required.
- An explicit application User-Agent resolved the CDN rejection observed with
  Python urllib's default header. The Racket HTTP client identifies the same app.
- Native unit and MCP client tests ran inside the sandbox. Local TCP callback
  tests and live network checks required execution outside it.
- No real tokens were created, and no images were uploaded or posts published.

## Repeat offline checks

```sh
uv sync --locked
bash scripts/check
```

The OAuth tests use temporary owner-only files and localhost connections only.
The test-only stdio entrypoint injects a fixture transport. The production server
has no fixture-mode environment switch. Runtime validation uses native codecs;
Python is an optional independent test client.

## Repeat the read-only live check

```sh
.venv/bin/python scripts/verify-stdio.py "$X_IMAGE_URL" /tmp/mcp-image-check.jpg
```

Use a direct image URL returned by the official X MCP and a new temporary output
path. The script forces writes off, checks the tool list and image block, then
writes the decoded bytes for visual inspection. It does not establish a persistent
cache. Inspect the result with a vision-capable client; assertions about a URL or
metadata alone do not establish image delivery.

## Live write acceptance

On 2026-10-08 the user explicitly authorized the generated Faië/Chaz image and
exact post text after a LibreWolf preview. An independent Python MCP client
called the native Racket server over stdio. X accepted upload
`2108303269189787648` and returned published post `2108303271739982011`
(https://x.com/i/status/2108303271739982011). No writes were retried. This confirms
the saved OAuth token, image upload, and post creation path. It does not yet
verify publishing through hosted ChatGPT or independent post readback.

A second authorized image-only reply succeeded through a local Racket client
calling the tool handlers: https://x.com/i/status/2108305465646137717, replying
to the first post. The user confirmed it worked. This second path did not use
the stdio transport or ChatGPT tunnel. No writes were retried.

Only after an explicit publishing request: configure the developer app, run
`racket racket/login.rkt`, complete authorization, and verify the intended account.
Upload the chosen image once, retain its media ID and expiry, publish the intended
text once, and verify through the official X MCP. Check X before retrying any
ambiguous error. Do not delete the post without a user request. Record only
non-secret observations.

## Remaining work

Tracked in [release checklist and backlog](release.md). Release preparation comes
before the next hosted ChatGPT publishing test; safe X error reporting is now
implemented and covered by synthetic regression tests. Token refresh now has synthetic regression coverage
and successful live rotation, persistence, and runtime credential checks.
Cancellation now has synthetic transport and application coverage. Decoder sandboxing is deferred while access stays private and single-owner.

## Live refresh acceptance — 2026-10-08

Using the existing confidential-client grant and local credentials, the production
refresh function was invoked early under the production file lock. X accepted it
and issued a different refresh token. The replacement record was atomically saved,
read back, and accepted by the normal access-token provider. The saved expiry was
not modified to induce the test. This verifies live refresh and persistence;
automatic expiry selection and concurrent access are covered by synthetic tests.
No upload or post was made. No credential values appeared in output.

The tunnel was stopped and restarted using a private local launcher sourcing a
mode-0600 client credential file. Status reported healthy and ready. Inspection
of the Racket child's environment confirmed client-secret presence, the expected
token-file path, and no direct access-token override. Secrets and the local
launcher remain ignored by Git. The local login script's permissions were also
restricted to 0600.

## Safe X error reporting — 2026-10-08

Synthetic tests cover HTTP status and operation context, recognized X problem
and OAuth error types, numeric error codes, retry timing, malformed/oversized
bodies, partial errors, and final MCP error content. Sentinel secrets in upstream
titles, details, messages, URLs, and headers must not reach tool results. Tests
also verify a failing write or token exchange is attempted only once. No live
failure was induced. See README for intentionally unsupported retry header forms
and the distinction between timing advice and permission to repeat a write.

Response formats and reset-header semantics were checked against the official
[X error reference](https://docs.x.com/x-api/fundamentals/response-codes-and-errors)
and [rate-limit documentation](https://docs.x.com/x-api/fundamentals/rate-limits).

## Cancellation — 2026-10-08

Six new deterministic pipe-based tests cover responsiveness during a blocked tool,
pre-submission cancellation without an X request, cleanup of managed ports and
subprocesses, post-submission success and uncertain failure with only one request,
malformed/unknown/repeated notifications, duplicate active IDs, the eight-request
limit, and token rotation/persistence before deferred cancellation. Storage-lock
reuse is verified after cancellation. Existing independent Python stdio client
checks continue to verify the asynchronous server's result contracts.

The implementation follows the [MCP cancellation specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation):
accepted cancellation suppresses the response; requests past an irreversible
boundary cannot be cancelled and may still return their outcome. Client reasons
are never logged. Hosted ChatGPT cancellation UI behavior remains unverified.

## First hosted CI run — 2026-10-08 (2026-10-09 UTC)

Source history was pushed to the public `faiema/master-control-program` repository
through SSH host `github-faiema`, with local `master` tracking remote `main`.
[GitHub Actions run 37883581680](https://github.com/faiema/master-control-program/actions/runs/37883581680)
passed both jobs at commit `9f50348`: the full test command on Ubuntu 24.04 with
Racket 9.3 and Python 3.13, and the redacted complete-history secret scan.
This verifies the hosted CI environment; it does not verify hosted ChatGPT
publishing or the deferred systemd deployment. No release tag was created.

GitHub repository images: public native-HTTPS → stdio-MCP → visual inspection
passed on 2026-10-09. Private canonical-image retrieval and visual inspection also passed on
2026-10-10; hosted ChatGPT acceptance remains pending. See [GitHub verification](github.md#verification).
