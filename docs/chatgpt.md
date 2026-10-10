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
Downloads are disabled until `MCP_CHATGPT_FILE_HOSTS` contains the trusted exact
download hostname. A rejected file reference reports only its hostname, so the
operator can verify it without logging its signed URL. Configure the verified
hostname in the tunnel process environment and restart/rescan tools. No hostname
is assumed from an example or guessed from a file ID.

For this user's 2026-10-07 test, ChatGPT supplied an accessible generated image
on `oaisdmntprwestus3.blob.core.windows.net`. After checking its HTTPS endpoint,
the local profile allows exactly that host. This is an observed account/region
example, not a global default or permission to allow all Azure storage accounts.

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
placeholder with the exact verified lowercase hostname, not a URL or wildcard.
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
arbitrary user-controlled DNS names, or wildcard domains. HTTPS certificate
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
`fetch_github_image`; hosted ChatGPT image delivery still needs confirmation.
