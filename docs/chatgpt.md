# ChatGPT connection and image handoff

## Current local posting setup — 2026-10-08

The user completed X authorization. The saved token was valid during the posting
tests. Automatic refresh is now implemented, and the user completed a new
login with `offline.access`. Live refresh and rotation succeeded, and the
runtime was restarted through ignored `.secrets/serve-chatgpt`, which loads
`X_CLIENT_SECRET` from private `.secrets/x-client.env` before executing Racket.
The child environment and healthy/ready status were verified without exposing
credentials. The tunnel was switched to the
normal server with `MCP_X_ENABLE_WRITES=1`,
`MCP_CHATGPT_FILES=1`, the verified exact storage hostname below, and an absolute
`MCP_X_TOKEN_FILE` path. It no longer uses the read-only test launcher.
ChatGPT needs to refresh its discovered tools to see `upload_x_media` and
`create_x_post`. Runtime health was verified during setup. On 2026-10-08, after image preview
and the user's publishing instruction, a local Python MCP client called the
native Racket server's upload and create tools successfully. X returned post
`2108303271739982011`: https://x.com/i/status/2108303271739982011.
An image-only reply also succeeded through a local Racket client calling the
tool handlers. These verify local publishing; hosted ChatGPT/tunnel publishing
remains to be exercised. Enabling the tools does not itself publish anything.

## Connection choice

Use [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
with our stdio server. It provides an outbound connection, avoiding a public HTTP
server. A tunnel ID, runtime key, and workspace association are required. The user
confirmed the Tunnel option is available on 2026-10-07. This is separate from
Codex's mobile remote-control connection.

Get the client from [Platform tunnel settings](https://platform.openai.com/settings/organization/tunnels)
or the official [latest release](https://github.com/openai/tunnel-client/releases/latest).
Start with `tunnel-client help quickstart`; use a runtime key, not an admin key.
Store secrets locally, outside tracked files. Initialize a profile:

```sh
tunnel-client init --sample sample_mcp_stdio_local \
  --profile master-control-program --profile-dir /absolute/repo/.secrets/tunnel-profiles \
  --tunnel-id YOUR_TUNNEL_ID \
  --control-plane-api-key-ref file:/absolute/repo/.secrets/tunnel-runtime-key \
  --mcp-command 'bash /absolute/repo/scripts/serve-chatgpt-readonly' \
  --health-listen-addr 127.0.0.1:0
```

Use the client's `doctor` before running the profile. Keep it running during
ChatGPT discovery and tool calls. For supervised operation, consult
`tunnel-client runtimes connect --help` and check `runtimes status` afterward.
Create the custom MCP plugin using Tunnel and the matching ID.

Our server requires the MCP initialized notification. Set
`MCP_STDIO_SEND_INITIALIZED_NOTIFICATION=true` in the tunnel process environment
(or use the client's matching flag) when validating and starting the tunnel.
Use `--profile-dir` with `doctor`/`run` when the profile is outside the default
directory. A local runtime was started and verified healthy/ready on 2026-10-07;
ChatGPT subsequently discovered both read-only tools after the server's repeat
initialization fix. The user confirmed seeing/describing a real X image returned
by the tool, then successfully round-tripped an accessible generated image.

The read-only launcher forces writes off, regardless of inherited settings.
This server has no application-level multi-user authorization; connect it only
through a tunnel restricted to your intended account/workspace. Do not share a
write-enabled instance with other users. X authorization remains separate.

## File handoff

The tool descriptors implement the documented
[ChatGPT file input contract](https://developers.openai.com/plugins/reference#file-apis):
`_meta["openai/fileParams"]` names `file`, whose object has required
`download_url` and `file_id`, plus optional `mime_type` and `file_name`.

Set `MCP_CHATGPT_FILES=1` to expose `inspect_chatgpt_image`, a read-only round trip
returning original MCP image content. The read-only launcher sets this flag.
Downloads are disabled until `MCP_CHATGPT_FILE_HOSTS` contains an authorized
exact download hostname or the explicit storage-family pattern below. A rejected file reference reports only its hostname, so the
operator can verify it without logging its signed URL. Configure the verified
hostname in the tunnel process environment and restart/rescan tools. No hostname
is assumed from an example or guessed from a file ID.

For this user's 2026-10-07 test, ChatGPT supplied an accessible generated image
on `oaisdmntprwestus3.blob.core.windows.net`. After checking its HTTPS endpoint,
the local profile initially allowed exactly that host. This is an observed account/region
example, not a global default or permission to allow all Azure storage accounts.

On 2026-10-11, the user's attempt to upload Ty's approved face reference supplied
`oaisdmntprwestus.blob.core.windows.net` (without the `3`) and was rejected before
download or upload. After verifying that exact endpoint over certificate-validated
HTTPS, the private launcher allowlist was expanded to contain both observed hosts,
comma-separated. The bare storage endpoint returned HTTP 400, which confirms
connectivity/TLS but does not test a signed file download. No wildcard was added;
all existing URL, redirect, size, MIME, and credential-isolation checks remain in
force. The local tunnel was restarted and reported healthy/ready; the running
Racket child's allowlist was verified to contain both exact hosts. The six
synthetic ChatGPT file tests passed. A fresh upload attempt in the originating ChatGPT context is required to
verify Ty's actual file handoff.

On 2026-10-13, the user supplied and authorized
`oaisdmntpreastus2.blob.core.windows.net`. It was added to the private launcher's
existing exact-host list. Certificate-validated HTTPS reached the storage
endpoint (HTTP 400 without a signed file request). Launcher syntax passed;
the restarted tunnel reported healthy/ready and the running Racket process's
allowlist contained the new host. An actual signed file download was not tested.
The endpoint check verifies connectivity, not ownership of an Azure account.

## Regional storage-family opt-in

On 2026-10-13, the user authorized replacing the three observed regional entries
with this narrowly supported pattern in the private launcher:

```sh
export MCP_CHATGPT_FILE_HOSTS='oaisdmntpr*.blob.core.windows.net'
```

This is a special-case matcher, not general glob support. It accepts the exact
`oaisdmntpr` prefix followed by 1–15 lowercase ASCII letters/digits and the exact
`.blob.core.windows.net` suffix (at most 24 characters in the account name).
Exact hostname entries still work and can be mixed with this entry. The pattern
is disabled unless configured. Bare Azure wildcards, extra subdomains, hyphens
in the account suffix, and oversized account names do not match.

Community precedent:

- [ServerFS MCP binary transfer](https://ntlx.github.io/ServerFS_MCP/docs/binary-transfer/#chatgpt-file-ingress)
  offers an opt-in for this observed regional account family.
- [X1pheR filesystem MCP](https://github.com/X1pheR/mcp-server-filesystem)
  documents the same family for runtime file ingress.
- [WebCodex deployment](https://github.com/yyjeqhc/webcodex/blob/main/docs/DEPLOYMENT.md)
  documents the same pattern for attachment imports.

These are community implementations, not an official account ownership registry.
The configured pattern trusts the naming family; matching it does not prove
OpenAI ownership. This change does not adopt those projects' other transport
implementations. Our existing HTTPS/TLS verification, no-redirect policy,
credential isolation, URL restrictions, timeout, size and image validation
remain unchanged. No signed file download is implied by configuration validation.

## Enable posting after the read-only checks

Complete X authorization as described in the [README](../README.md). Replace
the read-only launcher in the tunnel profile with the normal Racket entrypoint:

```sh
env -u X_ACCESS_TOKEN MCP_X_ENABLE_WRITES=1 MCP_CHATGPT_FILES=1 \
  MCP_CHATGPT_FILE_HOSTS=YOUR_VERIFIED_FILE_HOST \
  MCP_X_TOKEN_FILE=/absolute/repo/.secrets/x-token.json \
  racket /absolute/repo/racket/server.rkt
```

Use this as the profile's MCP command, restart the runtime, and refresh the
custom plugin's tools in ChatGPT. A new conversation should discover
`upload_x_media` and `create_x_post` alongside the read tools. Replace the host
placeholder with an authorized exact lowercase hostname or the supported
`oaisdmntpr*.blob.core.windows.net` pattern, not a URL.
Enabling writes grants clients with access to this instance the configured
owner's posting capability. Keep that access private. See the
[official refresh instructions](https://developers.openai.com/plugins/deploy/connect-chatgpt).

The read-only launcher always overrides `MCP_X_ENABLE_WRITES`; setting it to `1`
outside that launcher will not enable posting. A remote server's loopback OAuth
callback also needs to reach the browser machine: arrange SSH local port
forwarding for `127.0.0.1:8765`, or authorize locally and transfer the token
securely to the dedicated account. Do not expose the callback publicly.

## Download restrictions

Only allow service-owned public download hosts that you trust; the allowlist is
operator configuration, not a caller argument. Do not permit private services,
arbitrary user-controlled DNS names, or generic wildcard domains. The only
supported wildcard is the explicit opt-in storage-family pattern above. HTTPS certificate
validation remains enabled. Credentials, ports, fragments, backslashes, control
characters, redirects, and unlisted hosts are rejected. Downloads have a
30-second deadline and 5 MiB cap; native decoding enforces existing format and
pixel limits. Neither file IDs nor signed URLs appear in tool results. File
bytes are not cached, resized, or recompressed.

With writes separately enabled, `upload_x_media` accepts exactly one of `file`
or the existing `image_base64`. File bytes use the same JPEG/PNG validation and
X upload path. This does not publish a post. The read-only launcher cannot expose
upload/post tools; switch to the normal entrypoint only for intended live writes.

## Acceptance checks

1. Confirm the tunnel is healthy and ready, and ChatGPT discovers the tools.
   Completed on 2026-10-07.
2. Call `fetch_x_media` with an existing X image URL and visually inspect it in
   ChatGPT. Metadata or a successful tunnel handshake alone is insufficient.
   Completed: the user confirmed ChatGPT sees/describes the returned image.
3. Pass an attached image to `inspect_chatgpt_image`; verify the download hostname
   before enabling it, then confirm dimensions and actual image content.
   A separate manually attached image has not been tested in hosted ChatGPT.
4. Repeat with an image generated in that ChatGPT conversation. The documented
   file-input contract does not establish that every generated image is available
   as a file in every client. Record actual web/Android behavior.
   Completed with an earlier accessible generated image in the user's ChatGPT
   conversation. The latest failed generation supplied no accessible file and
   could not be inspected. Client platform was not separately recorded.
5. Only on an explicit publishing request, authorize X and test the intended
   upload/post. Never publish as part of connection diagnostics.

Synthetic tests exercise file handoff and upload through an independent MCP
client. Hosted image retrieval and generated-file inspection are additionally
confirmed by the user's live ChatGPT tests. Live X authorization/upload/posting
are confirmed through the local stdio client as recorded above, but not yet
through hosted ChatGPT. The downloaded tunnel binary lives in `/tmp`; configure a
durable installation and startup policy before treating this as an always-on
service. Manage this test process with `tunnel-client runtimes status` and
`tunnel-client runtimes stop`, using alias `master-control-program`.

## GitHub image setup — 2026-10-10

The private launcher also loads GitHub authorization from the mode-0600,
Git-ignored `.secrets/github-token.env`. The tunnel was restarted and reported
healthy/ready; GitHub credential presence in its Racket child was verified without
printing the token. A separate local stdio MCP client retrieved the private
canonical image successfully, and the original image was visually inspected.
See [GitHub verification](github.md#verification). Refresh tool discovery for
`fetch_github_image` after adding the tool.

GitHub image uploads were subsequently enabled with `MCP_GITHUB_ENABLE_WRITES=1`
in the private launcher. The restarted tunnel reported healthy/ready, and local
MCP discovery through that launcher confirmed `upload_github_image` has write
annotations and ChatGPT file input. The user reports the existing token has
read/write permission. The user subsequently confirmed that upload, fetch-back,
and visual inspection all succeeded in another ChatGPT conversation on
2026-10-10. The exact commit receipt and client platform were not supplied here.


## GitHub text setup — 2026-10-11

The private launcher now sets `MCP_GITHUB_TEXT_STATE_DIR` to the absolute
repository `.secrets/github-text-state` directory (mode 0700). The existing
GitHub write flag also exposes `upload_github_text`; `fetch_github_text` is
available by default. The tunnel was restarted and reported healthy/ready.
Live text checks through a separate local MCP client using the production
launcher passed; see [the exact results](github.md#live-text-acceptance--2026-10-11).
After restarting Codex, connected fetch/update/exact read-back and keyed receipt
replay passed; see [connected acceptance](github.md#connected-text-acceptance--2026-10-11).

The subsequent `patch_github_text` implementation uses the same GitHub write flag
and persistent journal. On 2026-10-11, the user selected the local runtime and it
was started with the new code; status reported healthy/ready. A connected text
read produced correlated JSON events in the tunnel stderr log. This client's
returned tool result did not expose `_meta.request_id`; clients needing an ID
before invocation should supply the optional `request_id` after schema refresh.
After catalog refresh, connected patch discovery, append, exact read-back,
keyed receipt replay and runtime log correlation passed on the disposable branch;
see [connected patch acceptance](github.md#connected-patch-acceptance--2026-10-11). See
[patch semantics and diagnostics](github.md#precise-edits-with-patch_github_text).
