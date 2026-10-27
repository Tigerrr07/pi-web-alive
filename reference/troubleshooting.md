# Troubleshooting

Start with `status.sh` and `~/.cache/piweb-keepalive.log`.

## pi-web and the watchdog

| Symptom | Cause / fix |
|---|---|
| Machine stops responding (even SSH) during the first start or while the agent works | Out of memory. Use ≥ 4 GB RAM |
| `REFUSING to start pi-web` in the log | The password file is missing or empty. Re-run `setup.sh` |
| A config change has no effect | The running watchdog and tmux session keep the old environment. Run `service.sh restart` |
| Host / forbidden error in the browser | The hostname isn't in `ALLOWED_HOSTS` or `CF_HOSTNAME`. `ts.sh serve` adds it; then run `service.sh restart` |
| tmux stuck at `Ok to proceed? (y)` | An old watchdog without `npx -y`. Re-run `setup.sh` |
| `tmux: unknown option -- e` | tmux < 3.0. Upgrade |
| Session drops right after a restart run inside pi-web | The restart killed its own tmux session. Run it in a normal terminal |
| `pkill -f piweb-keepalive` kills your own shell | `-f` matches the command itself. Use `service.sh stop/restart` |
| Linux: stops after logout | Linger is off. Run `sudo loginctl enable-linger $USER` |
| macOS: not back after a reboot, or unreachable while asleep | The LaunchAgent and the Tailscale app need a login. Enable auto-login and use `pmset` |
| WSL: not back after a Windows Update restart until someone logs in | The task was registered non-elevated. Re-run `register-task.ps1` elevated. In `windows` mode, also set Tailscale to unattended |
| WSL: pi-web disappears after a while | WSL went idle or was updated. You need `vmIdleTimeout=-1` plus the 5-minute task |

## Tailscale

| Symptom | Cause / fix |
|---|---|
| Linux: `Access denied: serve config denied` | Run `sudo tailscale set --operator=$USER` |
| "Serve is not enabled on your tailnet" | Open the printed link |
| `own`: device missing or `Logged out` | Run `ts.sh up <name>` again. Login links expire |
| WSL `own`: ping works, but HTTPS stalls at the TLS handshake | MTU 1280 on WSL. The scripts set `TS_DEBUG_MTU=1180`; kill an old tailscaled so the watchdog restarts it |
| WSL `windows`: 502 | Windows can't reach `127.0.0.1:<PORT>`. Test with `curl.exe -I http://127.0.0.1:<PORT>/` and check `localhostForwarding` / `networkingMode` in `.wslconfig` |
| macOS: the app window opens when the CLI runs | `TAILSCALE_BE_CLI=1` is missing. The scripts set it |

## Cloudflare

| Symptom | Cause / fix |
|---|---|
| cloudflared never starts; the log says `not behind Cloudflare Access` | The Access app is missing or the hostname doesn't match. Check with `cf-tunnel.sh check` |
| New route, but `Could not resolve host` locally | The router caches NXDOMAIN for up to 30 minutes. The scripts retry via 1.1.1.1 DoH; browsers wait, or test over mobile data |
| The Continue button is greyed out in the dashboard | No connector yet. Run `cf-tunnel.sh connect` |
| `Add at least one AUD tag` | Press Enter after pasting the AUD |
| Error 1033 / 502 | cloudflared isn't running, or the Service URL port is wrong. Run `cf-tunnel.sh status` and check `~/.cache/cloudflared.log` |
