# GitHub repository images

`fetch_github_image` addresses [issue #2](https://github.com/faiema/master-control-program/issues/2):
return an actual image content block, not a URL or base64 text result.

Inputs are `repository_full_name` (`owner/repository`), `path` (relative file path),
and optional `ref` (branch, tag, or commit SHA). Omit ref or pass null for the
default branch. The tool is read-only and available by default.

The server looks up file metadata with the official contents API, downloads the
raw blob by immutable SHA, checks the size and Git blob SHA-1, then validates and
returns the unchanged image. Metadata includes repository, path, requested ref,
blob SHA, MIME, dimensions, and byte count. The ref is the caller's selection,
not a resolved commit ID; the blob SHA identifies the exact returned content.
GitHub may resolve a symlink to a normal repository file; provenance describes
the bytes GitHub returned for that path. Directories and submodules are rejected.

Static PNG/JPEG/WebP, at most 5 MiB and 40 megapixels, are supported. No resizing,
recompression, caching, or writes occur. Git LFS pointers, animations, and other
formats are rejected. Generation/editing reuse depends on the client's ability
to pass a received image to its renderer; this tool cannot guarantee that handoff.

## Original-file handoff: unresolved runtime dependency

The requested `fetch_github_image_file` capability is **not implemented**. The
existing reader returns original bytes, but this does not establish that web
ChatGPT can materialize those bytes in its Python container. The local
`scripts/verify-github-image.py` client can save them; that is a different runtime
and is not end-to-end acceptance of the requested handoff.

Documentation reviewed on 2026-10-11:

- The [OpenAI plugin UI reference](https://developers.openai.com/plugins/reference)
  describes widget file uploads and download URLs for already authorized file
  IDs. It does not establish a server-side staging contract for this sidecar.
- The [OpenAI MCP extensions specification](https://github.com/openai/mcp-extensions/blob/main/docs/spec.md)
  lists file resources as desktop-only in its platform table and excludes classic
  ChatGPT from that table. Resource writes update a host-provided, writable file
  opened through a file entrypoint; they do not authorize minting arbitrary host
  file URIs.

No supported staging/materialization pair for the target web conversation has
been identified. This is an unresolved integration dependency, not proof that
every ChatGPT deployment lacks such a capability. A server-local path, invented
`file_uri`, standard MCP resource URI, or visual attachment alone must not be
reported as a usable ChatGPT connector file reference.

Resume implementation when a supported host contract can be exercised: stage
verified bytes, receive a genuine authorized reference, materialize it in the
target conversation, and compare hashes there. Reuse the existing GitHub
authentication and blob verification. Keep runtime failures separate from
GitHub retrieval failures and preserve the existing image-only tool.

The requested acceptance fixture is
`faiema/faie-canon:canon/characters/megan/references/face-three-quarter-canonical.png`,
expected blob `ef0f5e10799f3a26bcc9a9818e6b301bfdd28224`, 2,168,392 bytes,
PNG 1144 × 1375. These are caller-supplied expectations, not a recorded successful
handoff. Completion additionally requires repeated matching hashes, explicit
empty/truncated-payload failures, unauthorized-access rejection, and a separate
background-edited output with the protected facial pixels unchanged. No target
ChatGPT-container materialization or pixel-preserving edit has been verified.

## Private repositories

Public files require no credential. Private files need this server's own GitHub
credential. The connected GitHub MCP's authorization is not available here, and
an SSH key (including the local `github-faiema` alias) is not an HTTP API token.

For a personal installation:

1. Open GitHub **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token** at
   [token settings](https://github.com/settings/personal-access-tokens).
2. Choose the repository owner, an expiration, and **Only select repositories**;
   select `faie-canon` (or the repository you want this server to read).
3. Under **Repository permissions**, set **Contents** to **Read-only**. Keep all
   other permissions at their defaults. Generate the token. Organization-owned
   repositories may require approval from the organization.
4. Supply the token through `MCP_GITHUB_TOKEN` in the server's private environment.
   Never paste it into chat, source files, or a command-line argument. For a
   temporary Bash terminal session, this prompts without echoing the token:

   ```bash
   read -rsp 'GitHub token: ' MCP_GITHUB_TOKEN
   printf '\n'
   export MCP_GITHUB_TOKEN
   racket racket/server.rkt
   ```

For the tunnel, the variable must be set in its private launcher environment and
the runtime restarted. Setting it in an unrelated terminal does not update an
already-running server. Tokens are not automatically refreshed; replace expired
or revoked tokens locally. GitHub App tokens can also be supplied, but automatic
App token minting is not implemented. A 404 can mean an inaccessible private
repository as well as an incorrect path or ref.

Credentials go only to `api.github.com` over verified HTTPS. Reads use GET; enabled image uploads use PUT to the contents endpoint.
No redirects, upstream download URLs, X tokens, or file-service credentials are
used. Raw upstream error bodies and headers are not exposed. The server remains
single-owner: any connected client can read repositories accessible to its token.

## Verification

`bash scripts/check` includes synthetic GitHub responses, credential isolation,
input encoding, file integrity, errors and real MCP image serialization through
the independent Python SDK. Ordinary tests do not call GitHub.

An explicit live read can save the returned MCP image for visual inspection:

```sh
.venv/bin/python scripts/verify-github-image.py \
  github/explore topics/racket/racket.png /tmp/racket-reference.png
```

The output path must not exist. For the issue's acceptance image, substitute
`faiema/faie-canon` and
`canon/characters/boie/references/face-luke-canonical.png`, with the token set in
the same terminal. Add `--ref COMMIT_OR_BRANCH` when desired.

On 2026-10-09 the public Racket logo passed native HTTPS, image validation, blob
integrity checking and stdio MCP delivery, and was visually inspected: PNG,
288×288, 11,101 bytes, blob `1cfd5120ea7187659de93983d272ce474ddc5352`.
On 2026-10-10 authenticated retrieval of the canonical image from
`faiema/faie-canon` succeeded through the production Racket server and independent
Python stdio MCP client. The returned PNG was visually inspected: 1145×1374,
2,228,365 bytes, blob `832a265c63db7d3e23411a79ad5e394505ced111`.
The private launcher now loads a mode-0600, Git-ignored GitHub credential file.
The tunnel was restarted and reported healthy/ready; the Racket child's GitHub
credential presence was verified without printing its value. Later that day, the
user confirmed a successful upload, fetch-back, and visible image in another
ChatGPT conversation. Image-generation/editing reuse remains unverified.

The implementation follows GitHub's
[contents API](https://docs.github.com/en/rest/repos/contents#get-repository-content)
and [raw blob API](https://docs.github.com/en/rest/git/blobs#get-a-blob), checked
2026-10-09. The contents API can intentionally return empty content above 1 MB;
the raw blob request avoids that limitation. Local limits remain smaller than
GitHub's maximum blob size.

## Upload an image to a repository

`upload_github_image` creates a real Git commit containing one original image.
Enable it with `MCP_GITHUB_ENABLE_WRITES=1` in the server environment and provide
`MCP_GITHUB_TOKEN` with **Contents: read and write** on the destination repository.
This setting is independent of `MCP_X_ENABLE_WRITES`; both default off. The
read-only launcher overrides both flags. The user reports the existing local
GitHub token has read/write access, and subsequently confirmed a successful live
upload in another ChatGPT conversation.

Required arguments:

- `repository_full_name`: owner/repository.
- `path`: destination ending in .png, .jpg/.jpeg, or .webp matching the actual image.
- `branch`: explicit existing destination branch.
- `message`: Git commit message.
- Exactly one source: `image_base64`, or `file` when ChatGPT file input is enabled.

Optional `expected_sha` authorizes replacement of that exact current blob.
Omit it (or pass null) for create-only. GitHub rejects creation at an existing
path without its SHA, and rejects stale replacement SHAs. Never fetch a SHA merely
to turn a failed create into an unauthorized overwrite. An expected SHA protects
that file's content, not the whole branch history. Protected branches and token
restrictions remain enforced by GitHub. No branch creation, PR creation,
multi-file transaction, issue attachment, Git LFS upload, or text fallback is
implemented by this tool.

Static PNG/JPEG/WebP up to 5 MiB and 40 megapixels are decoded for validation and
committed unchanged. ChatGPT file inputs use the same exact-host allowlist and
credential-free downloader as other file tools. The upload returns MIME,
dimensions, byte count, blob SHA, commit SHA, and an immutable GitHub file URL.
No image bytes, signed download URL, or token appear in the receipt.

A timeout or invalid response can leave an uncertain commit. The tool never
retries automatically, even after a conflict. Inspect the destination before
retrying. Cancellation before submission stops the operation; once submission
starts the bounded request finishes so it can report the result. Cancellation
cannot undo a commit. Use uploads serially for a branch to avoid conflicting
contents operations.

Example instruction for another conversation, with the image attached and this
MCP enabled:

> Use upload_github_image to commit this image to OWNER/REPO on branch BRANCH at
> images/reference.png, with commit message "Add reference image". Create only;
> do not replace an existing file. Use the attached file directly.

If the path already exists, ask the user whether replacement is intended before
supplying its current blob SHA. Agents must not transcribe base64 by hand.

Implementation follows GitHub's [create/update contents API](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents),
checked 2026-10-10. Ordinary tests use synthetic writes only. On 2026-10-10 the
user confirmed that uploading in another ChatGPT conversation, fetching the image
back, and visually inspecting it all succeeded. The exact destination, commit
receipt, hash comparison, and client platform were not supplied in this thread;
this is user-confirmed acceptance, not an independently inspected commit receipt.

## UTF-8 text files

`fetch_github_text` reads a UTF-8 file up to 1 MiB. Inputs are
`repository_full_name`, `path`, and optional `ref` (branch, tag, or commit; null
means the default branch). It returns `content`, `blob_sha`, repository, path,
requested ref, and `size_bytes`. Bytes are fetched by immutable blob SHA and
checked against Git's blob hash and metadata size before strict UTF-8 decoding.
Empty files are supported. Unicode, BOMs, line endings, dialogue, and Markdown
are preserved without normalization or content rewriting.

`upload_github_text` is exposed under the existing `MCP_GITHUB_ENABLE_WRITES=1`
gate and uses the same isolated `MCP_GITHUB_TOKEN` credential. Supply an App
installation token or a fine-grained token with Contents: write for the selected
repository. This server does not borrow the connected GitHub plugin's session or
mint/refresh installation tokens. Repository access and branch protection remain
GitHub-enforced; there is no additional repository allowlist. This is a
single-owner server, so restrict the token's repository selection appropriately.

Required arguments are `repository_full_name`, `path`, explicit `branch`,
`message`, and the complete `content` string. Optional `expected_sha` authorizes
replacement of that exact blob. Omit it or pass null to create only. The tool
checks the destination first, then passes the caller's SHA to the Contents API,
so a concurrent change between lookup and submission cannot silently overwrite a
different version. A conflict returns `current_sha` when observable. A missing or inaccessible replacement target returns
`PATH_NOT_FOUND`. If GitHub reports a conflict but the subsequent lookup fails, the
original HTTP error is retained rather than inventing a current SHA. A 404 may
also mean an inaccessible repository or ref; it is never proof of public absence.

After submission, the tool checks returned path, blob SHA and commit SHA, then
reads the file at that **immutable commit** and verifies its exact UTF-8 bytes.
The receipt includes repository, branch, path, operation (`create` or `replace`),
blob SHA, commit SHA, byte count, media type, `verified: true`, and `commit_url`.
Verification does not assert that a moving branch still points to that commit.
Atomic multi-file updates remain a later enhancement.

### Precise edits with `patch_github_text`

`patch_github_text` edits an existing UTF-8 file through the same write gate,
credential, Contents API, SHA checks, cancellation boundary, and durable journal
as `upload_github_text`. Required fields are `repository_full_name`, `path`,
`branch`, `expected_sha`, `message`, and `operation`. It cannot create files.
GitHub enforces token repository permissions and branch protection; the local
`authorization_completed` event means the write gate and credential format passed,
not that GitHub has already approved the eventual write.

| Operation | Edit fields | Behavior |
| --- | --- | --- |
| `replace_exact` | `anchor`, `replacement` | Replace exactly one literal occurrence; empty replacement deletes it. |
| `insert_after` | `anchor`, `content` | Insert immediately after exactly one literal occurrence. |
| `append` | `content` | Append exactly the supplied text; works on an empty existing file. |

Omit edit fields unused by the chosen operation. Empty anchors, missing anchors,
and multiple matches (including overlapping matches) fail before submission.
There is no regex interpretation, fuzzy matching, newline insertion, trimming,
or Unicode normalization. The original file is fetched and its bytes checked
server-side; unchanged content, BOMs and mixed line endings are preserved.
Each edit string and the resulting file must fit the 1 MiB UTF-8 limit.
The whole-file expected SHA still protects against concurrent changes anywhere
in the file. Patches do not merge concurrent edits automatically. They reduce
caller payload size; GitHub's Contents API still receives the complete new file.

Example for a fresh, authorized edit (substitute the reviewed current SHA):

```json
{
  "repository_full_name": "owner/repository",
  "branch": "editing-branch",
  "path": "notes.md",
  "expected_sha": "<current 40-character blob SHA>",
  "message": "Add meeting note",
  "operation": "append",
  "content": "\n## Next meeting\n\nReview the outline.\n",
  "idempotency_key": "notes-next-meeting-001"
}
```

The verified receipt has the usual commit URL, commit/blob SHAs and byte count;
`operation` is `replace_exact`, `insert_after`, or `append`. Patch errors retain
the structured diagnostics below; anchor failures use `INVALID_CONTENT` with
`reason: ANCHOR_NOT_FOUND` or `ANCHOR_AMBIGUOUS` at `patch_validation`.

Optional `idempotency_key` claims the patch arguments **before** the current file
is read or edited. Replaying a verified key returns its receipt even though the
branch has changed. Recovery from failed verification reads only the saved
immutable commit and verifies its saved blob SHA and size; it never reapplies
the patch. An unresolved submission is never resubmitted. Upload and patch key
fingerprints cannot collide merely because they would produce the same content.
Existing upload journal fingerprints remain compatible.

Use this tool for authorized edits under its own authorization and safety
requirements. A connector-specific refusal, including an ambiguous safety-check
refusal, establishes that channel's outcome; it does not by itself establish a
policy prohibition or determine this tool's outcome. Confirmed applicable policy
prohibitions still apply. No content-based policy classifier is added to this server.

### Idempotency and uncertain writes

For retry protection, configure `MCP_GITHUB_TEXT_STATE_DIR` to an absolute,
persistent directory writable only by the server owner, then supply an optional
`idempotency_key` (1–256 characters). Reuse the **same key and arguments** when a
response is lost. The journal is server-wide and survives process restarts;
all instances handling retries must share it on a filesystem supporting atomic
directory creation and rename. A key is claimed exclusively before submission.
Receipts are atomically replaced. The journal stores argument fingerprints,
commit provenance and safe errors, never document bodies, messages, raw keys or
tokens. Per-key directories have owner-only permissions.

- A verified receipt is returned unchanged without another GitHub request.
- A recorded commit whose verification failed is verified again without another
  submission. Failure responses include its known commit SHA and URL.
- A known pre-submission failure or HTTP rejection is replayed as that failure.
  After resolving it and reviewing the destination, use a new key for a new edit.
- Reusing a key with different arguments is rejected.
- An incomplete claim or lost submission response remains unresolved. It is
  never automatically resubmitted. Inspect the destination and reconcile manually;
  matching file bytes alone do not prove which attempt created a commit.

Retain the journal for as long as keys may be retried. Removing it, using another
state directory, or supplying a new key removes that retry protection. No
automatic cleanup is performed. The journal protects against process termination
and lost client responses; it is not a guarantee against filesystem loss or
power failure. Without a key, each explicit call is a new attempt. The tool never
retries a PUT automatically, with or without a key. Calls in one server process
are serialized; coordinate other writers to the same branch separately.

### Structured diagnostics and policy boundaries

The 2026-10-12 description cleanup changes guidance only. Authorization, SHA
checks, journal behavior, error classification and GitHub requests are unchanged.
Tool descriptions are defined directly in `racket/server.rkt`; no generated
description source was found. MCP `tools/list` through the production launcher
returned the revised descriptions and unchanged write annotations. The tunnel
was restarted and reported healthy/ready. This conversation's connected catalog
still exposed the old descriptions afterward, so refresh plugin tool discovery
to load the new metadata; restarting the server alone did not refresh that cache.
The full offline check passed 100 Racket tests and 12 Python tests, including a
new MCP `tools/list` description regression check.

Text tools return JSON in both MCP `structuredContent` and a text content block.
Failures set `isError: true` and include `category`, `message`, `stage`,
`write_state`, and `automatic_retry: false`. Optional fields include
`http_status`, `current_sha`, and known commit provenance.

Categories are `AUTH_REQUIRED`, `PERMISSION_DENIED`, `PATH_NOT_FOUND`,
`SHA_CONFLICT`, `INVALID_CONTENT`, `GITHUB_API_ERROR`, and
`UNKNOWN_UPSTREAM_ERROR`. A GitHub 403 can also indicate rate limiting; the
message explains that ambiguity. Malformed responses and transport failures do
not imply a policy rejection. `POLICY_BLOCKED` is reserved for explicit evidence
from an enforcing layer; the current transport has no such signal and never
emits that category. A rejection before MCP receives the request is outside this
server's diagnostic visibility and cannot produce a server-side result.

`write_state` is `not_submitted`, `rejected` (an HTTP 4xx submission response other than a timeout),
`uncertain`, or `committed` (GitHub confirmed a commit, even if verification then
failed). Correlated stage logs on stderr are described below. Documents and credentials
are not logged. Invalid MCP envelopes and unknown/disabled tools retain ordinary
JSON-RPC errors.

### Request correlation and diagnosis

All three text tools accept optional `request_id`: exactly 32 lowercase hex
characters, generated independently for each invocation. Never put a credential,
document fragment or idempotency key in it. If omitted/null, the server generates
one. Responses include the invocation ID in MCP result `_meta.request_id`, outside
`structuredContent` and the text receipt so durable receipt replay stays identical.
Clients that hide `_meta` should supply and retain their own ID before calling.
The ID is diagnostic, not an authorization token or retry key. It may change on
an otherwise identical keyed retry.

Each enabled text-tool handler logs JSON lines with `event: github_text`,
`request_id`, `tool`, `stage`, and UTC Unix `timestamp_ms`. Events are flushed to
stderr and serialized within a process. The `request_received` event precedes
argument validation and includes character/UTF-8 byte counts for supplied
`content`, `anchor`, and `replacement`, plus `arguments_json_bytes` for the
server's reserialized argument object. That last count is **not** the original
client script size, whitespace-preserving wire size, or MCP envelope size.
No document text, anchors, replacement text, paths, messages, raw retry keys,
credentials, or raw upstream errors are logged.

Stages include `request_validation`, `authorization`, `authorization_completed`,
`existing_file_lookup`, `sha_verified` (metadata SHA comparison),
`content_preparation`, `existing_file_fetched` (patch source bytes verified),
`patch_validation`, `patch_validated`, `github_api_submission` (before PUT),
`github_commit_submitted` (GitHub confirmed the expected commit),
`commit_verification`, and `commit_verified`.
`request_completed` includes available commit/blob SHAs, byte count and operation;
`request_failed` includes the failing stage, safe category and write state.
Read-only calls and journal replays naturally skip stages they do not execute.
The journal remains a retry ledger, not a request log.

To diagnose a failed call:

1. Record the invocation ID, UTC time, tool name, size counts and client error;
   preserve a connector refusal as evidence of that channel's outcome. Distinguish
   it from a confirmed applicable policy prohibition; do not infer one from an
   ambiguous failure.
2. Search the actual runtime's captured stderr for that ID. A matching
   `request_received` establishes that the text handler was reached. A structured
   failure or `request_failed` identifies the server stage; HTTP status identifies
   a GitHub API response. An incomplete trace after submission is uncertain.
3. With verified log coverage and the correct active runtime, absence of that ID
   is evidence that the handler was not reached. Check transport/dispatcher logs,
   disabled-tool or malformed-envelope errors, process availability, retention
   and logging failures before concluding that enforcement blocked invocation.
   Absence alone cannot identify the enforcing layer. A server cannot return a
   structured error for a request it never received. Pre-submission cancellation
   can also leave a received event without a completion/result.

### Reported upstream rejection — 2026-10-11

The user reported a verified update to `faiema/faie-canon` main,
`docs/ownership-map.md`, commit
[`c83834e57bf23ae67989ec84a3bc3ad74d8e74a0`](https://github.com/faiema/faie-canon/commit/c83834e57bf23ae67989ec84a3bc3ad74d8e74a0),
with a 9,563-byte result (approximately 9,400–9,500 content characters). Shortly
after approximately 06:30 PDT, an upload to `canon/characters/megan/character.md`
returned an explicit OpenAI safety-check rejection and no structured MCP result.
The user estimates 5,000–5,200 content characters and 5,100–5,300 UTF-8 bytes for
the rejected request; these exclude JSON/tool overhead. Exact payload counts and
per-call timestamps are unavailable. The smaller rejected payload weakens a
simple size-limit explanation and establishes no subject-matter cause.

Read-only inspection of the local tunnel log found a forwarded request at
06:30:12.791 PDT followed by text stages through `commit_verification`, then a
forwarded request at 06:30:17.004 followed by read stages. The next recorded
forwarded event was at 06:50:32.674, with no following text stages in the inspected
log. The reported successful commit SHA was absent from that log. Old stage
lines have neither their own timestamps nor file/request/commit identifiers;
proximity to dispatcher events is not reliable per-call attribution. These
observations do not confirm which layer rejected the later call. The local
runtime was stopped when inspected. No rejected payload was retrieved or retried.
The new correlation fields support future ordinary-call diagnosis; they cannot
retroactively reconstruct this incident.

These tools evaluate authorized requests independently of unrelated connector
failures. This does not authorize actual policy violations or evasion of applicable
enforcement. Text is supplied directly, with only the documented Contents API
transport encoding applied internally.

The implementation uses the official
[Contents API](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents),
checked 2026-10-11. Offline tests cover create/update, stale SHA and create
conflicts, Unicode and exact integrity, error classification, write gating,
cancellation, journal replay, uncertain submissions, verification recovery, and
Python MCP client serialization and receipt replay across server restarts. The offline suite does not establish live acceptance; see the separate live check below.


### Live text acceptance — 2026-10-11

On the user's explicit instruction, a separate branch
`mcp-test/text-writes-2026-10-11` was created from `faiema/faie-canon` main. A local
Python MCP client used the production Racket server through the same private
launcher as the tunnel to create and replace only
`.mcp-tests/text-write-acceptance.md`:

- Create commit: [`8a031ce082351afaf89c1739512143a12800be5f`](https://github.com/faiema/faie-canon/commit/8a031ce082351afaf89c1739512143a12800be5f),
  blob `55aa9df1ecedfe826e05bd60196ec38a3a802ad2`, 167 bytes.
- Update commit: [`ff9bea3c41e8b45a44f161f50c40aaf5c7d33b48`](https://github.com/faiema/faie-canon/commit/ff9bea3c41e8b45a44f161f50c40aaf5c7d33b48),
  blob `090c1feebecb12473b6724f84848a3caf0716829`, 214 bytes.

Exact read-back preserved Faië, Maië, curly quotes, CRLF, Markdown, Japanese and
an emoji. Stale-SHA replacement and create-over-existing returned SHA_CONFLICT
with the current SHA and left the file unchanged. After restarting the local
MCP client/server process, repeating both keyed writes returned the original
receipts. Independent GitHub reads confirmed exactly two commits from the initial
test-branch head, only the disposable file changed, and main stayed unchanged.
The branch and file remain available for the hosted ChatGPT acceptance check.
The replay test simulates a caller losing its result; it does not simulate a
live HTTP connection breaking during GitHub submission (covered offline).

The private launcher now configures persistent retry state at
`.secrets/github-text-state` (absolute path in the environment, directory mode
0700). The existing tunnel was restarted and reported healthy/ready. The local
MCP client discovered both new tools. This conversation's hosted tool catalog
still lacked them, so a hosted ChatGPT text-tool call remains unverified pending
plugin refresh and a new conversation. Successful local MCP calls are not proof
of successful hosted tool routing or policy approval.

### Connected text acceptance — 2026-10-11

After the Codex restart, this conversation exposed both Master Control Program
text tools. The connected `fetch_github_text` returned the expected existing blob
`090c1feebecb12473b6724f84848a3caf0716829` from the disposable branch and file above.
The connected `upload_github_text` preserved that content and appended exactly:

```text
Connected MCP test: exact UTF-8 read, update, and keyed receipt replay.
```

The appended line ends with CRLF, matching the existing text. Replacement used
the freshly fetched blob SHA and key `live-text-2026-10-11-connected-update`,
with commit message `Verify connected MCP text update`.

- Commit: [`9c315ea68e69bc5128d9142fa137702af14dbbc5`](https://github.com/faiema/faie-canon/commit/9c315ea68e69bc5128d9142fa137702af14dbbc5).
- Blob: `1672c8e170594285c7de955100c7c5824d8012ee`; 287 UTF-8 bytes.
- Receipt: operation `replace`, media type `text/plain; charset=utf-8`,
  `verified: true` (server verification at the immutable commit).
- Connected branch read-back matched the submitted content exactly, including
  Unicode and CRLF, and returned the receipt's blob SHA.
- Replaying the identical keyed request returned an identical structured receipt,
  including the same commit SHA.

This establishes successful connected-tool routing for this test in Codex,
beyond the earlier local stdio check. The only connected write targeted
`.mcp-tests/text-write-acceptance.md` on `mcp-test/text-writes-2026-10-11` in
`faiema/faie-canon`. The test branch and retry journal were retained.

### Resume after Codex restart (completed above)

The following was the handoff for the completed connected test; do not repeat
the append operation with a new key or a newly fetched expected SHA.

The user authorized live testing with a disposable file, and is restarting Codex
to refresh its available tools. Continue the existing test; do not recreate the
branch or rerun the initial create operation with a new idempotency key.

1. Check whether the connected Master Control Program now exposes
   `fetch_github_text` and `upload_github_text`. Local stdio acceptance already
   passed; the remaining test must use the connected tools to verify that route.
   If they remain absent, report the discovery limitation; restarting Codex alone
   has not been demonstrated to refresh the plugin's registered tool metadata.
2. Use connected `fetch_github_text` on `faiema/faie-canon`, path
   `.mcp-tests/text-write-acceptance.md`, ref `mcp-test/text-writes-2026-10-11`.
   The last verified blob was `090c1feebecb12473b6724f84848a3caf0716829`.
3. For the authorized connected-client write test, preserve the fetched text and
   append one clearly labeled test line, using its freshly fetched `expected_sha`
   and a distinct stable key such as `live-text-2026-10-11-connected-update`.
   Use only the existing test branch. Read back and check exact content, then
   replay the identical keyed request and confirm the same commit receipt.
   On an uncertain outcome, reuse that key and identical arguments; do not
   manufacture a fresh attempt or silently replace the expected SHA.
4. Record the connected-tool result and commit receipt here. Do not modify main,
   character canon, or other repository files. Do not delete the test branch or
   retry journal during verification. A channel-specific refusal is not by itself
   a universal policy determination. Confirmed applicable policy prohibitions
   remain binding.

Implementation and documentation changes are saved in this working tree but
have not been committed or pushed. The full offline suite passed 89 Racket and
10 Python tests before the additional restart test; that test and subsequent
focused text checks also passed. Two existing live image-check scripts had their
expected tool lists updated and were syntax-checked. Existing receipts are in
ignored `output/github-text-acceptance-2026-10-11.json`; persistent idempotency
records are in ignored `.secrets/github-text-state`. Never print credentials from
`.secrets`. The live test helper `/tmp/mcp-live-text-acceptance.py` is temporary
and should not be blindly rerun: its initial-head assertions assume a fresh test
branch. The recorded receipts above are the durable evidence.


### Patch acceptance — 2026-10-11

The full offline suite passed 99 Racket tests and 12 Python tests. This covers
literal append/replace/insert, BOM/Unicode/mixed-newline preservation, missing and
overlapping anchors, stale SHA, UTF-8/size validation, permissions, cancellation,
uncertain submission, immutable-commit recovery, and patch receipt replay across
process restarts. The Python MCP client also verified correlation metadata and
JSON stderr events without document text or retry keys.

A separate live Python MCP client used the production private launcher to patch
only `.mcp-tests/text-write-acceptance.md` on `faiema/faie-canon` branch
`mcp-test/text-writes-2026-10-11`:

- Append: [`5af9ed4f3a5e18a66b832d7b6ce797bbb7ee54e8`](https://github.com/faiema/faie-canon/commit/5af9ed4f3a5e18a66b832d7b6ce797bbb7ee54e8),
  blob `e2815aa033c7c0c8beae599382fdfb434aa54f6f`, 335 bytes.
- Exact replacement: [`d80d6dcea6067cfd9ec407533f7ed05b5b8ca71b`](https://github.com/faiema/faie-canon/commit/d80d6dcea6067cfd9ec407533f7ed05b5b8ca71b),
  blob `f2708ae2cea1d80268e1e2a1a2821d650cdb8b01`, 340 bytes.

Both returned verified receipts, matched exact immutable read-back, and replayed
identically with the same idempotency keys and fresh correlation IDs. Stale-SHA
and missing-anchor attempts returned structured errors and left the file unchanged.
The final test line is `Patch MCP test: Faië and Maië, exact replacement.` with
CRLF. No main or canonical-file writes were requested. Live receipts are saved
in ignored `output/github-patch-acceptance-2026-10-11.json` (JSON Lines).
The one-time helper `/tmp/mcp-live-patch-acceptance.py` must not be blindly rerun;
its initial SHA assumes the pre-patch file. An initial sandboxed read failed on
network access before any write; the authorized network-enabled run passed.

The user selected the local runtime, which was started healthy/ready with this
implementation. A connected `fetch_github_text` on the disposable file produced
`request_received` through `request_completed` in the actual tunnel log under
ID `69d4537e7382d3828e3a2ec311658162`. The hosted result omitted `_meta`, so supply
`request_id` explicitly when available in the refreshed schema. The current
conversation at that point did not expose `patch_github_text`. Local live acceptance
and connected read logging are verified; connected patch discovery and invocation
remain to be checked after the plugin catalog refreshes. Do not substitute a
local call as evidence of hosted patch acceptance, or retry the rejected canon
edit as an acceptance test.

### Connected patch acceptance — 2026-10-11

After catalog refresh, Codex exposed the connected `patch_github_text` tool.
Connected fetch confirmed the previous blob
`f2708ae2cea1d80268e1e2a1a2821d650cdb8b01`. The authorized append targeted only
`.mcp-tests/text-write-acceptance.md` in `faiema/faie-canon`, branch
`mcp-test/text-writes-2026-10-11`, and added this line with CRLF:

```text
Connected patch MCP test: exact UTF-8 append and keyed receipt replay.
```

- Commit: [`5a384203a5932e8e28e5121de1a5d3b7748416fc`](https://github.com/faiema/faie-canon/commit/5a384203a5932e8e28e5121de1a5d3b7748416fc).
- Blob: `04abf5b484bac0025651d605f318d044e552630c`; 412 UTF-8 bytes.
- Receipt: `operation: append`, `verified: true`, immutable-commit verification.
- Connected branch read-back exactly matched the original content plus the
  72-byte line, preserving Unicode and CRLF, and matched the receipt's blob SHA.
- Replaying the original expected SHA, content, message and idempotency key
  `live-patch-2026-10-11-connected-append` returned the identical structured receipt.
  Do not repeat the append with a new key or refreshed expected SHA.

Explicit request IDs `c011202610114abc8000000000000001` through
`c011202610114abc8000000000000004` identify the initial read, patch, read-back and
replay respectively. The actual local tunnel log contains matching events:
the patch reached `github_api_submission`, `commit_verified` and
`request_completed`; replay completed without another submission. An initial
read used an invalid request-ID format and returned `INVALID_ARGUMENT` before
lookup; the corrected read used the required 32 lowercase hexadecimal characters.

This verifies connected patch discovery, invocation, exact read-back, durable
receipt replay and runtime correlation in Codex. No writes targeted main or
character canon, and the rejected canon edit was neither retrieved nor retried.
The disposable branch and retry journal remain available. Receipt evidence is
also saved in ignored `output/github-connected-patch-acceptance-2026-10-11.json`.
