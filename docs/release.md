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
- [ ] Improve X error reporting with bounded, selected safe fields and retry timing.
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
42 Racket tests and 5 Python tests with zero skips.

Before committing, inspect `git status --short` and the staged diff. Include
`racket/chatgpt-file.rkt`, its tests, the readonly launcher, new documentation,
the license, and CI. Do not stage `.secrets/`, local output, or machine-specific
profiles. A source archive contains source and fixtures, not installed runtimes
or third-party dependencies; those retain their own licenses.

## Token refresh — implemented, new grant saved; live verification pending

Automatic refresh now requests `offline.access`, stores rotating tokens atomically,
and locks the shared token file across processes. Synthetic tests cover expiry,
rotation, concurrent callers, process restart, rejected authorization, malformed
responses, and network failure. Refresh happens before writes, with no automatic
retry of an uncertain write. See README authentication setup for the one-time
reauthorization and runtime restart. On 2026-10-08 the user completed the new
login; metadata inspection confirmed offline.access, a refresh token, a saved
client ID, and mode 0600. This is a confidential-client grant: the running
server needs X_CLIENT_SECRET. That environment and a successful live refresh
have not yet been verified; this agent session has no client secret configured.

## Follow-up work

- Cancellation: read notifications while tools execute, stop work before
  submission where possible, and distinguish cancellation from an unknown
  outcome once a write has been submitted to X.
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
