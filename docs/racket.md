# Racket implementation and reusable components

The application now runs without Python. The server, HTTP requests, image worker,
OAuth login, token storage, and X request translation are Racket modules. Native
image codecs are accessed through Racket's draw library and a small libwebp FFI
binding. Python remains only as an independent MCP client in development checks.

## Application modules

| Module | Responsibility |
| --- | --- |
| `racket/server.rkt` | Tool schemas, annotations, validation, and dispatch |
| `racket/http.rkt` | Official-host HTTPS, verified TLS, response bounds, no retries/redirects |
| `racket/github-http.rkt` | Separate GitHub token and GET/contents-PUT HTTPS transport, bounded safe errors |
| `racket/github-upload.rkt` | Independent GitHub write gate, image validation, create/replace payload and commit receipt |
| `racket/github-media.rkt` | Repository image lookup, immutable blob retrieval and hash verification |
| `racket/x-errors.rkt` | Bounded safe X/OAuth error summaries, operation names, status advice and retry timing |
| `racket/media.rkt` | CDN URL allowlist, base64, provenance, unchanged image content |
| `racket/chatgpt-file.rkt` | Opt-in ChatGPT file references, explicit download-host allowlist, bounded credential-free downloads |
| `racket/image-worker.rkt` | Native image validation in a bounded subprocess with an empty environment |
| `racket/auth.rkt` | X scopes, token exchange, expiry checks and automatic refresh |
| `racket/login.rkt` | Local authorization flow and terminal interaction |
| `racket/x-api.rkt` | Independent write gate, upload/post request and response translation |
| `racket/common.rkt` | Application-safe exceptions and deadline/JSON adapters |

Racket's standard [HTTP client](https://docs.racket-lang.org/net/http-client.html)
uses an explicitly [secure TLS context](https://docs.racket-lang.org/openssl/index.html)
with certificate and hostname verification. Networking connects directly; proxy
support has not been implemented or tested.

## Reusable modules

The `racket/lib/` modules contain no X endpoints, tool names, scopes, or account
logic. They remain source modules in this repository, with no separate package
release or speculative extension system.

| Module | Public interface and purpose |
| --- | --- |
| `mcp-stdio.rkt` | `serve-tools` multiplexes bounded input and up to eight tool workers; handles cancellation, response serialization, and resource cleanup; `rpc-error` raises safe protocol errors |
| `cancellation.rkt` | Per-request cancellation state, an application-selected side-effect boundary, and protected credential transactions; no X policy |
| `deadline.rkt` | `call-with-deadline` runs a thunk under a child custodian and calls a supplied timeout handler; resources are closed on success as well as failure |
| `json.rkt` | `parse-json` accepts exactly one JSON value and rejects trailing data |
| `pkce.rkt` | `make-pkce`, `random-state`, and `base64url`, using cryptographic randomness and S256 |
| `oauth-loopback.rkt` | Bounded localhost authorization-code callback, state validation, duplicate rejection, denial and timeout handling |
| `secret-file.rkt` | `write-private-json` atomically replaces a mode-0600 JSON file; `call-with-private-json-lock` coordinates threads and processes using a stable sibling lock file; existing parent permissions are preserved |
| `image.rkt` | `inspect-static-image` takes byte/pixel limits and returns an `image-info` record without changing the input bytes |
| `webp.rkt` | Small libwebp decoding binding, used by the image validator |

`serve-tools` supports the tools-only subset of
[MCP 2025-11-25 stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
and its [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).
The invocation function remains responsible for tool argument validation,
authorization, and constructing MCP results. This separation allows another
project to reuse the transport without importing the X application. Tests run
it with an unrelated server identity and handler.

Tool workers have individual custodians; cancellation closes managed ports and
kills child processes. Accepted pre-submission cancellations suppress responses.
An application marks irreversible submission with `mark-side-effect-started!`;
subsequent cancellation is ignored so the bounded operation can report its
outcome. `call-with-cancellation-shield` defers cancellation through credential
rotation and storage-lock release. Stdin EOF drains accepted tool calls before
shutdown; oversized frames or input failures shut down session resources. A
process shutdown can still lose the outcome of a submitted write.

Repeated initialization returns server metadata without resetting a completed
handshake. This supports tunnel discovery reusing one stdio subprocess. The
first initialization still requires `notifications/initialized` before tools.

The generic image library can be used directly for trusted data. This application
runs it in a separate process for untrusted media: a parent custodian can kill a
stalled native codec even if the codec is executing C code. The worker inherits
an empty environment, receives only bounded image bytes, and returns JSON
metadata or a safe error. It has no HTTP or credential operations.
This is process isolation for crashes and deadlines, not an OS security sandbox:
the child runs as the same user and retains that user's filesystem and network
permissions. Clearing its environment does not prevent access to secret files.
Stronger containment is a follow-up if access expands beyond one trusted owner.

## Image validation

PNG chunk boundaries, CRCs, animation chunks, and dimensions are inspected before
native decoding. JPEG frame dimensions are checked before pixel allocation, and
an end marker is required. WebP dimensions and animation status come from
[libwebp's documented decoder API](https://developers.google.com/speed/webp/docs/api).
All three formats are actually decoded, then their original bytes are returned.
Progressive/grayscale/CMYK JPEG, PNG alpha/palette modes, and lossless WebP have
synthetic regression coverage.

The WebP binding uses the ABI-checked export behind `WebPGetFeatures`, with the
structure and ABI version from `webp/decode.h` (0x0210). libwebp is required for
WebP images. Racket `draw-lib` and its Cairo, JPEG, and PNG dependencies handle
the other formats. This setup has been exercised on Linux with Racket 9.3;
other platforms have not been verified.

Compared with the Python prototype, native validation performs full pixel
decoding and conservatively rejects APNG containers even with one frame. It does
not reproduce lenient acceptance of damaged files by a header-only validator.
No image transformation is performed.

## Limits and remaining work

- HTTP deadline: 30 seconds; image worker deadline: 15 seconds.
- Image input: 5 MiB and 40 megapixels; API response body: 1 MiB.
- MCP input frame: 8 MiB. An oversized frame closes the session after an error.
- OAuth callback: bound to 127.0.0.1, five-minute overall deadline, five-second
  per-connection deadline, and 8 KiB request-header limit. Callback responses
  contain no codes, tokens, or upstream error details.
- Tool requests are serial. Notifications never invoke tools. Cancellation does
  not interrupt a running operation; deadlines still apply. Check the account
  before repeating an uncertain write.
- Writes are hidden unless `MCP_X_ENABLE_WRITES=1`; the API layer separately gates
  them before credential access or network traffic.
- Live account authorization, upload, posting, and an image reply succeeded from
  local clients on 2026-10-08. Ordinary tests still use mock token responses,
  synthetic images, and local callback requests only.
- Secure MCP Tunnel and file-reference tools passed local tests and user-confirmed
  live ChatGPT image checks; see [ChatGPT setup](chatgpt.md). The tunnel currently
  runs as a local test process. Automatic token refresh has synthetic coverage,
  plus a successful live refresh/rotation and restarted-runtime credential check. Asynchronous
  processing and video support remain unimplemented.

See the [release checklist and backlog](release.md) for prioritized follow-up.

The Python runtime and its console entrypoints were removed after native image,
OAuth, request-construction, and MCP contracts passed. Commit `aaa39e4` retains the
prototype if historical comparison is needed. `tests/fixtures/contracts.json`
preserves its synthetic observable results; Python SDK client tests now compare
against those records without importing a Python server or Pillow.
