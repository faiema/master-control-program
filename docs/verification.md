# Verification and next steps

## Observed on 2026-10-07

- Official X-MCP account and recent-post reads succeeded. Attachments contained
  URLs, dimensions, and media keys, but no image content.
- No image-byte fetch, upload, or public post creation tool was exposed.
- All 22 tests passed with zero skips using MCP 1.30.0 and Pillow 12.3.0.
  This includes a separate stdio process, tool discovery, and validation errors.
- Dependencies installed and locked in `uv.lock`; Git is initialized.
- Live stdio fetch returned a JPEG image block: 1200 × 900, 279708 bytes.
  The client decoded it and the local image viewer delivered it to the vision
  model: a fairy and a gremlin beside monitors describing a broken image pipeline.
  This verifies the local path, not automatic rendering in hosted ChatGPT.
- The CDN rejected the default urllib User-Agent with HTTP 403. Explicitly
  identifying the application as `master-control-program/0.1` succeeded.
- The supplied URL returned a smaller rendition than the dimensions in X metadata;
  no local resizing occurred. Use an original-size URL when required.
- Sandbox subprocess execution stalled; the complete offline suite and live
  check succeeded outside the sandbox.
- Racket is installed and is the standard target; Python is the accepted prototype.

## Acceptance without live writes

1. Install dependencies, generate a lockfile, and run all tests with zero skips.
2. Connect a real MCP client over stdio and inspect the tool list.
3. Pass an image URL from the official X MCP to `fetch_x_media`.
4. Confirm the response contains an image block with unchanged bytes and correct
   MIME type. Confirm a vision model can describe the actual image. A URL or a
   synthetic content-dictionary test alone does not satisfy this requirement.
5. Enable writes and inspect annotations without invoking the write tools.

## Live write acceptance

Only after an explicit user publishing request: configure the developer app,
complete OAuth, and verify the intended account. Upload the chosen image once,
retain its media ID and expiry, publish the chosen text once, and verify through
the official X MCP. Check X before retrying any ambiguous error. Do not delete the
post without a user request. Record non-secret observations only.

## Remaining work

- Verify OAuth and an explicitly requested live upload/post.
- Evaluate Racket MCP/HTTP support and port the prototype's contracts.
- Design authenticated remote transport and client-native attachment handoff
  for ChatGPT web. Local stdio plus base64 is not that finished workflow.
- Add token refresh only when needed. No offline scope is currently requested.
- Async processing, GIF/video, post/media-key lookup, archives, and persistent
  caches are intentionally absent. Verify X retention terms before adding storage.

## Repeat the read-only live check

```sh
.venv/bin/python scripts/verify-stdio.py "$X_IMAGE_URL" /tmp/mcp-image-check.jpg
```

Use a direct image URL returned by the official X MCP and a new temporary output
path. The script forces writes off, checks the tool list and image block, and
writes the decoded bytes for visual inspection. It does not create a persistent
cache. Inspect the output with a vision-capable client; passing assertions alone
does not establish visual rendering. Ordinary tests never download live media.
