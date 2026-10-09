# Sample systemd deployment (after launch)

Durable deployment is deferred until after launch. These are example files, not
an installed or server-validated deployment:

- [master-control-program.service](../deploy/systemd/master-control-program.service)
- [service.env.example](../deploy/systemd/service.env.example)

The unit runs `tunnel-client run` in the foreground; the tunnel launches Racket
as its stdio child. Use systemd as the supervisor, not `runtimes connect` inside
the service. Restart-on-failure applies to the tunnel process; a live process
with failing requests still needs health monitoring. Five failures within five
minutes stop the restart loop; after fixing the cause, use `systemctl reset-failed`.

## Expected layout

| Location | Purpose |
| --- | --- |
| `/opt/master-control-program` | Source checkout, readable but not writable by the service account |
| `/usr/local/bin/tunnel-client` | Verified executable installed outside `/tmp` |
| `/usr/bin/racket` | Racket installation with required native codec/TLS dependencies |
| `/etc/master-control-program` | Tunnel profile, runtime key, and service environment |
| `/var/lib/master-control-program` | Service-owned state and rotating X token file |
| `/run/master-control-program/health.url` | Current loopback health URL |

Create a dedicated `mcp-x` system user and group, with no interactive login and
home directory `/var/lib/master-control-program`. Prepare that state directory
owned by `mcp-x`, mode 0700, before transferring the X token. systemd also manages
its ownership and mode using `StateDirectory`. Keep `x-token.json` owned by
`mcp-x`, mode 0600; the directory must be writable for atomic replacement and
locking. Do not run two machines with copies of the same rotating grant.

Verify the server's Racket version and codec dependencies using
[the runtime notes](racket.md). Authorize locally as described in the README,
then securely transfer the token to the service account. The callback is not
part of this service. Store the confidential app's client secret in
`/etc/master-control-program/service.env`, owned by root with mode 0600.
systemd reads that file and passes the variables to the service; never put real
credentials in the checked-in example or the unit's command line.

## Profile preparation

Create `/etc/master-control-program` as root, group `mcp-x`, mode 0750. Store the
runtime key as `tunnel-runtime-key`, owned by root, group `mcp-x`, mode 0640.
Generate the profile using the installed client's CLI (verify flags with `init
--help` when upgrading):

```sh
sudo /usr/local/bin/tunnel-client init \
  --profile master-control-program \
  --profile-dir /etc/master-control-program \
  --tunnel-id YOUR_TUNNEL_ID \
  --control-plane-api-key-ref file:/etc/master-control-program/tunnel-runtime-key \
  --health-listen-addr 127.0.0.1:0 \
  --mcp-command 'env -u X_ACCESS_TOKEN -u CONTROL_PLANE_API_KEY -u OPENAI_ADMIN_KEY /usr/bin/racket /opt/master-control-program/racket/server.rkt'
```

Make the generated `master-control-program.yaml` readable by `mcp-x` (root-owned,
group `mcp-x`, mode 0640). Use a runtime key, not an administrator key. The client
secret remains available to Racket for refresh. Keep health/UI bound to loopback;
no public inbound listener is needed. The sample environment disables publishing
and ChatGPT file inputs until explicitly enabled. See [ChatGPT setup](chatgpt.md)
for exact file-host configuration and account access boundaries.

## Installation and checks (when deployment is scheduled)

After preparing dependencies, account, paths, credentials, and profile:

```sh
sudo install -m 0644 deploy/systemd/master-control-program.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/master-control-program.service
sudo systemctl daemon-reload
sudo systemctl enable --now master-control-program.service
sudo systemctl status master-control-program.service
sudo journalctl -u master-control-program.service -n 50 --no-pager
```

Inspect health using the URL in `/run/master-control-program/health.url`. Verify
MCP discovery, restart, reboot recovery, and token refresh before calling this
production-ready. Connectivity loss is not necessarily a process failure. Avoid
verbose payload logging and do not copy logs containing signed URLs or secrets.

The unit makes system files read-only and permits state/runtime directory writes;
it also uses a private temporary directory. These settings do not isolate the
image worker from credentials available to its service account. Do not add
`MemoryDenyWriteExecute` without testing Racket's runtime requirements. Shutdown
has a 45-second limit and may interrupt an in-flight write or token exchange;
check the outcome before resubmitting. Nothing here automatically retries posts.
