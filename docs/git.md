# Git repositories on faie.net

`git_repository` uses ordinary Git over authenticated HTTPS. No GitHub API is
involved. It is exposed only when `MCP_GIT_DIRECTORY` and an explicit whitespace
separated `MCP_GIT_REPOSITORIES` allowlist are configured. Names include `.git`.
The server clones each repository on first use into its own persistent workspace.

```
MCP_GIT_DIRECTORY=/private/state/git
MCP_GIT_REPOSITORIES="xyzzy.git master-control-program.git"
MCP_GIT_ORIGIN=https://faie.net
MCP_GIT_CREDENTIAL_FILE=/private/config/git-credential
MCP_GIT_ENABLE_WRITES=1
```

The credential file contains the worker's `username:token`, mode 0600. Credentials
are passed as origin-scoped HTTP headers through the Git process environment,
never embedded in URLs, command arguments, tool results or Git config files.
Redirects, hooks, external diff, text conversion and credential helpers are
disabled. Keep the workspace directory private (0700), owned by the MCP account.

For this host, `scripts/run-with-faie-git` supplies the installed credential path,
the seven current repositories and a cache under `~/.local/share/`. Add
`MCP_GIT_ENABLE_WRITES=1` to enable edits and pushes. Point the stdio/tunnel launch
command at this script to enable Git alongside existing tools. It preserves the
existing X, GitHub and ChatGPT file settings; it does not configure a hosted tunnel.

Every invocation takes `repository` and `action`:

| Action | Additional inputs | Behavior |
| --- | --- | --- |
| `status`, `branches` | none | Local workspace state / local and remote branches |
| `fetch` | none | Refresh remote refs without merging or changing files |
| `tree`, `log`, `diff` | optional `ref` (default HEAD) | Recursive tree, latest 30 commits, or worktree diff against ref |
| `read`, `image` | `path`, optional `ref` | Committed UTF-8 text or original MCP image content |
| `write` | `path`, `content`, `expected_commit` | Replace/create exact UTF-8 text and stage it |
| `delete` | `path`, `expected_commit` | Remove and stage a tracked file |
| `commit` | `message`, `expected_commit` | Commit all staged edits |
| `branch` | `branch`, `expected_commit` | Create a local branch at HEAD |
| `checkout` | `branch`, `expected_commit` | Switch to an existing local branch |
| `merge` | `ref`, `expected_commit` | Merge a branch/tag/commit with normal conflict handling |
| `abort_merge` | `expected_commit` | Abort an in-progress merge |
| `push` | destination `branch`, `expected_commit` | Push HEAD to that remote branch; no force |

Read `status` first; pass its full `head` as `expected_commit` for every write.
For an empty repository, the initial head is forty zeros. A stale head fails
before mutation. Reads use immutable commits resolved from the requested ref.
File edits allow only relative paths and refuse symlinks and `.git` components.
Text writes are limited to 1 MiB; command output to 6 MiB; each command to 120s.
Image decoding uses the existing 5 MiB / 40 megapixel image validation.

For a remote branch not yet local, use `fetch`, then create a local branch with
`branch`, switch with `checkout`, and `merge` the `origin/branch` ref. Normal Git
fast-forward and merge rules apply. To update the current branch, fetch and merge
its `origin/branch` ref. A conflicted merge returns an error and leaves conflicts
in the workspace. Inspect `status`/`diff`; resolve files with `write`, then `commit`,
or use `abort_merge`. `read` returns committed text, while `diff` shows pending
edits. No operation automatically commits, pushes, or retries another operation.

Workspaces are shared by this single owner's calls, serialized per repository.
Staged edits persist across calls; `commit` includes all staged edits. This is
not a multi-user workspace system. A process crash can leave `<repo>.lock`:
confirm no operation is running before removing that empty lock directory.
After timeout/cancellation or a failed push, fetch and inspect remote history
before retrying: the remote may already have accepted it. No durable write
idempotency is claimed. Raw Git errors are suppressed to protect credentials and
document text. Use trusted local Git diagnostics when an error needs inspection.

The first version covers normal branch, merge and file workflows. It does not
offer arbitrary Git commands, branch deletion, force pushes, rebase, reset, Git
LFS, submodules or binary uploads. Existing GitHub tools remain available.

Verification: `raco test racket/git-tests.rkt` uses local disposable repositories,
with no live network calls. The full project check includes this suite. Live HTTPS
acceptance is a separate disposable-repository check, never a normal test write.

The system service uses explicit paths under `/etc/master-control-program` and
`/var/lib/master-control-program`; it does not use the interactive user's home
or the wrapper defaults. See [deployment](deployment.md) for the live settings.
