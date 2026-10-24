# Deployment

## Active deployment: faie.net, 2026-10-23

MCP now runs on `faie.net` as the enabled system service
`master-control-program.service`, under the dedicated `mcp-x` account.
No running MCP was found on the former candidate host `g` or locally at cutover.
The previous local `.secrets/serve-chatgpt` is disabled; its saved token and
journal are stale rollback material, not another active installation.

The source checkout is `/opt/master-control-program`, initially deployed at
`3c942bdc0dfff0543adf31fe7ea5cd84c30c81b4`. Racket 8.16 and native image
dependencies are installed. The checksum-verified official tunnel-client 0.0.18
bundle is under `/usr/local/lib/master-control-program/tunnel-client-0.0.18`,
with `/usr/local/bin/tunnel-client` pointing to its executable.

Configuration and credentials live under `/etc/master-control-program`
(root-owned, group `mcp-x`, directory 0750, secret files 0640). The installed
profile launches `bash /etc/master-control-program/serve-chatgpt`; this launcher
loads the migrated `x-client.env` and `github-token.env`. Unlike the sample unit
below, the installed unit therefore omits `EnvironmentFile`. The existing
tunnel identity, X/GitHub write gates, ChatGPT file support and authorized
regional storage-family allowlist were preserved. No public listener was added.

Mutable state lives under `/var/lib/master-control-program`, owned by `mcp-x`,
with directories 0700 and files 0600. This includes `x-token.json` and
`github-text-state`; all 81 journal files were checked byte-for-byte at migration.
Treat this host's state as authoritative. Never restart a second machine with
copies of the rotating X grant or an old write journal.

Operations:

```sh
ssh faie.net sudo systemctl status master-control-program
ssh faie.net sudo systemctl restart master-control-program
```

The loopback health base URL is saved in
`/run/master-control-program/health.url`; GET `/health` reports both `live` and
`ready`. Version 0.0.18 does not serve `/ready`. Set profile `log.file` to the
empty string for standard output; literal `stdout` is treated as a filename.
The unit routes stdout/stderr to journald. Never enable raw HTTP logging.

On 2026-10-24, the Git feature (`6bd08a3`) was landed on `main` for deployment.
The service launcher configures `MCP_GIT_DIRECTORY` as
`/var/lib/master-control-program/git`, the seven repositories listed in
`scripts/run-with-faie-git`, origin `https://faie.net`, and the separate
`/etc/master-control-program/git-credential` file (root:mcp-x, 0640 within the
0750 configuration directory). Git writes are enabled. Git's persistent workspaces
are owned by `mcp-x`, mode 0700; they are separate from the source checkout.

The host's journald had failed before deployment with exit 243/CREDENTIALS in
LXC. `/etc/systemd/system/systemd-journald.service.d/container-credentials.conf`
clears `ImportCredential=`, avoiding the unsupported credential mount; journald
then started successfully. This overrides only journal credential imports. The
MCP service must be restarted after restoring journald to reconnect its output.
Check `systemctl is-active systemd-journald` as well as the MCP service.

Validation on the destination: 101 Racket tests and 12 independent Python MCP
tests passed, with no skipped tests or live publishing. The tunnel reported live
and ready, including after a service restart. A connected MCP call fetched
`github/explore:topics/racket/racket.png` and returned the actual 288×288 PNG,
verified against blob `1cfd5120ea7187659de93983d272ce474ddc5352`; the image was
visually inspected. Boot enablement was checked, but the host was not rebooted.
X refresh/posting and a new signed ChatGPT file download were not exercised at
cutover. No test posts or repository writes were made.

For rollback, stop this service first and transfer its latest token and complete
journal securely before starting any replacement. Do not reuse pre-migration
state after the new service has handled requests.

## Sample installation for another host

These are generic example files; the live deployment differences are above:

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
for file-host allowlist configuration and account access boundaries.

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
