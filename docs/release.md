# Release checklist and backlog

## First release: personal, self-hosted sidecar

One owner and one X account per instance. Users run their own server and provide
their own credentials. Source publication does not expose the maintainer's live
instance or authorize anyone to publish through it. The runtime is native Racket;
Python is an optional test client. GNU AGPL version 3 only (`AGPL-3.0-only`) applies
to this repository's original source, documentation, and synthetic fixtures.

## Before launch

- [x] Add the GNU AGPLv3 license and source identifiers.
- [x] Exclude personal generated images, prompts, and posting receipts (`output/`).
- [x] Document single-owner access and the actual image-worker isolation boundary.
- [x] Reconcile current verification claims and list all exposed tools.
- [x] Add a common test command that rejects skips and empty discovery.
- [x] Add CI with pinned actions, locked test dependencies, and a redacted secret scan.
- [x] Review the complete release diff, including previously untracked source files.
- [x] Run checks from a clean release snapshot and run the full-history secret scan.
- [ ] Observe the first successful GitHub CI run; local tests do not verify hosted CI.
- [x] Improve X error reporting with bounded, selected safe fields and retry timing.
      Keep tokens, signed URLs, and arbitrary response bodies out of errors.
- [ ] After release preparation, verify an explicitly authorized image post from
      hosted ChatGPT through the tunnel, and verify an ordinary attached image.
      Record web/Android/desktop separately; never publish during ordinary tests.
- [ ] Verify the chosen server's Racket version and native dependencies before
      advertising support. Linux with Racket 9.3 is locally verified; other
      versions and Windows are not yet verified.
- [ ] Approve the final publication/tag separately from local preparation.

For local checks:

```sh
uv sync --locked
bash scripts/check
```

The check command requires both runtimes and fails on missing dependencies or
skipped Python tests. Set `MCP_TEST_PYTHON` to an absolute Python executable to
reuse an existing test environment when checking a clean export. No production
credentials are needed; callbacks bind localhost and API calls use fixtures.

Local preparation verified on 2026-10-08: a clean 41-file source export, excluding
credentials and personal output, passed 40 Racket cases and 4 independent MCP
client cases with zero skips. Gitleaks 8.24.2 found no leaks in either the two
existing commits or the exported release files. The binary matched the upstream
SHA-256 checksum. This is a scanner result, not a guarantee that all possible
secrets are detectable. GitHub CI itself has not yet run. The subsequent token-refresh changes passed
42 Racket tests and 5 Python tests with zero skips. Error-reporting regression
coverage subsequently expanded the suite to 46 Racket tests and 5 Python tests.

Before committing, inspect `git status --short` and the staged diff. Include
`racket/chatgpt-file.rkt`, its tests, the readonly launcher, new documentation,
the license, and CI. Do not stage `.secrets/`, local output, or machine-specific
profiles. A source archive contains source and fixtures, not installed runtimes
or third-party dependencies; those retain their own licenses.

## Token refresh — implemented and live-verified

Automatic refresh now requests `offline.access`, stores rotating tokens atomically,
and locks the shared token file across processes. Synthetic tests cover expiry,
rotation, concurrent callers, process restart, rejected authorization, malformed
responses, and network failure. Refresh happens before writes, with no automatic
retry of an uncertain write. See README authentication setup for the one-time
reauthorization and runtime restart. On 2026-10-08 the user completed the new
login. A deliberately early live refresh then succeeded through the production
refresh function under its file lock: X rotated the refresh token, replacement
tokens were saved and read back, and the normal token provider accepted them.
No expiry was altered and no upload/post endpoint was called. Synthetic tests
cover the automatic expiry trigger; this live check did not wait two hours.

The local tunnel was restarted with an ignored private launcher that loads
`.secrets/x-client.env` (mode 0600). Its Racket child was checked for the presence
of `X_CLIENT_SECRET`, the correct token-file path, and absence of `X_ACCESS_TOKEN`,
without printing credential values. Runtime status reported healthy and ready.
This is still a local test deployment, not a boot-persistent service.

## Cancellation — implemented with synthetic verification

The transport reads cancellation notifications while tools execute, releases
pre-submission request resources, and suppresses cancelled responses. Once an
upload or post crosses its submission boundary, cancellation is ignored; the
bounded request returns success or an error describing an uncertain outcome.
Token rotation and storage-lock release finish before deferred cancellation.
Tests cover running reads, port/subprocess cleanup, both write boundaries,
malformed/unknown notifications, duplicate IDs, capacity, and refresh persistence.
The current suite has 52 Racket tests and 5 Python tests. Hosted ChatGPT UI
cancellation behavior has not been separately verified.

## Follow-up work
- Durable deployment: install the tunnel outside `/tmp`, use a dedicated service
  account and a systemd unit, and test restart/reboot and credential expiry.
  No public inbound listener is needed for the private tunnel.
- Stronger native-decoder containment: reconsider OS-enforced filesystem,
  network, and resource restrictions if access expands beyond one trusted owner.
  The current subprocess is a crash/timeout boundary, not a security sandbox.
- Reuse generic Racket modules in a real second project before packaging them.

Shared public hosting would be a separate project milestone: authenticate callers,
isolate their credentials, and enforce account authorization before enabling
writes. Video/async media, archives, and caching are outside this first release.
Check current X retention terms before adding persistent X-content storage.
