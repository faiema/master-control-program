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
