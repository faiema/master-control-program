# Verification and next steps

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
raco test racket/tests.rkt racket/oauth-tests.rkt racket/lib-tests.rkt
uv sync --locked
.venv/bin/python -m unittest discover -s tests -v
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

Only after an explicit publishing request: configure the developer app, run
`racket racket/login.rkt`, complete authorization, and verify the intended account.
Upload the chosen image once, retain its media ID and expiry, publish the intended
text once, and verify through the official X MCP. Check X before retrying any
ambiguous error. Do not delete the post without a user request. Record only
non-secret observations.

## Remaining work

- Verify live OAuth and an explicitly requested upload/post.
- Design authenticated remote transport and client-native image handoff for hosted
  ChatGPT. Local stdio plus base64 is not the finished web workflow.
- Add token refresh only when needed; no offline scope is requested now.
- Async processing, GIF/video, post/media-key lookup, archives, and persistent
  caches remain absent. Verify X retention terms before adding storage.
- Reuse the isolated library modules in a concrete second project before creating
  a separately distributed package or general extension mechanism.
