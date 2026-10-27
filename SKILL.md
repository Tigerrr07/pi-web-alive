---
name: pi-web-alive
description: Keeps pi-web (the pi coding agent's browser UI) running in tmux on Linux, WSL2 or macOS, and sets up remote access from phones and other computers via Tailscale or Cloudflare Tunnel + Access. Use when installing, checking, changing or troubleshooting pi-web or its remote access.
argument-hint: "[setup | status | tailscale | cloudflare | <problem>]"
---

# pi-web-alive

```
phone / laptop ──Tailscale──> https://<device>.<tailnet>.ts.net ──(tailscale serve)──┐
any browser ──> https://piweb.<domain> ── Cloudflare Access ── Tunnel ── cloudflared ─┤
                                         127.0.0.1:<PORT>  pi-web (password required) ◄┘
  tmux session "piweb": a loop restarts pi-web 5s after it exits
  ~/bin/piweb-keepalive.sh: every 30s recreates tmux, keeps serve on, runs cloudflared only behind Access
  started by systemd --user (Linux) · launchd (macOS) · Task Scheduler (WSL)
```

Scripts live in `${CLAUDE_SKILL_DIR}/scripts`. Below, that directory is called `$S`. In other agents, it is the `scripts/` folder next to this file.

## Rules

- **The user does these steps.** Give them the link or command, then wait:
  - Tailscale login links
  - the Cloudflare dashboard
  - pasting the tunnel token
  - sudo passwords
  - elevated PowerShell
  - installing missing prerequisites (ask first)
- **Never restart from inside the pi-web you manage.** That means `service.sh restart|stop|uninstall`, and `install` on Linux/macOS. It kills the tmux session you are running in. The script refuses when `PI_WEB_ALLOWED_HOSTS` is set; ask the user to run it in a normal terminal. `setup.sh`, `ts.sh` and `cf-tunnel.sh setup|others|check` are safe.
- **Never put the tunnel token** on a command line or in chat.
- **Never use** `tailscale funnel`, router port forwarding, `-H 0.0.0.0` or `sudo cloudflared service install`.

## Prerequisites

- ≥ 4 GB RAM
- Node ≥ 22.19
- tmux ≥ 3.0
- curl
- a C/C++ toolchain (for node-pty)
- pi: `npm i -g @earendil-works/pi-coding-agent`. Then the user runs `pi` and `/login`.

`setup.sh` checks all of these.

## Set up

```bash
bash $S/setup.sh --port 30141   # config, password, watchdog; safe to re-run; one port per instance
bash $S/service.sh install      # autostart
bash $S/status.sh               # expect pi-web 307, API 401 (the first start takes ~30s)
```

| OS | `service.sh install` does | Note |
|---|---|---|
| Linux | systemd user unit + linger | If linger fails, the user runs `sudo loginctl enable-linger $USER` |
| macOS | LaunchAgent | Runs only after login, like the Tailscale app. For reboots, enable auto-login; to prevent sleep, run `sudo pmset -c sleep 0` |
| WSL | Prints the `register-task.ps1` command | The user runs it in an elevated PowerShell. It starts at boot (S4U), re-checks every 5 minutes and sets `vmIdleTimeout=-1`. If S4U fails, add `-UsePassword` |

## Remote access

- **Tailscale** (your own devices, private): run `bash $S/ts.sh serve`, then `service.sh restart`. See [reference/tailscale.md](reference/tailscale.md).
- **Cloudflare Tunnel + Access** (any browser, no app): see [reference/cloudflare.md](reference/cloudflare.md). Fail-closed: the tunnel runs only while the hostname redirects to Cloudflare Access.

## Day-to-day

| Task | Command |
|---|---|
| **Turn off** (stays off, also after a reboot) | `bash $S/service.sh stop` (normal terminal; on WSL it pauses the scheduled task) |
| **Turn on** again | `bash $S/service.sh start` |
| Health check | `bash $S/status.sh` (the `switch:` line in `service.sh status` shows on/off) |
| Apply changes to env, password or script | `bash $S/service.sh restart` (normal terminal) |
| Restart pi-web only | `tmux kill-session -t piweb` (recreated within 30s; browser sessions drop) |
| Watch the console | `tmux attach -t piweb`, detach with `Ctrl-b d` |
| Password / log | `cat ~/.config/pi-web/password` · `tail -f ~/.cache/piweb-keepalive.log` |

pi-web updates itself: `npx` uses `@latest` on every restart.

## Files and scripts

- **Config:**
  - `~/.config/pi-web/env`: `PORT`, `ALLOWED_HOSTS`, `TS_MODE`, `TS_HOSTNAME`, `CF_HOSTNAME`, `CF_OTHER_HOSTNAMES`
  - `password` (600, required: without it the watchdog refuses to start)
  - `cf-token` (600)
- **Runtime:** `~/bin/piweb-keepalive.sh`, copied by `setup.sh`. pi-web keeps running even if this skill folder is deleted.
- **Scripts:**
  - `setup.sh`
  - `service.sh install|start|stop|restart|status|uninstall`
  - `ts.sh serve|install|up|status|off`
  - `cf-tunnel.sh setup|connect|others|check|status|disable`
  - `status.sh`
  - `register-task.ps1` (WSL)

## Problems

Run `status.sh` and read the log first. Then see [reference/troubleshooting.md](reference/troubleshooting.md).

## Security and removal

- pi-web can run any command as the user. Keep these:
  - the password
  - `127.0.0.1` only
  - access only through `tailscale serve` or an Access-protected tunnel
  - an Access policy that allows only the user's email
  - a tailnet with only trusted users: by default every device in the tailnet can reach the URL. If others share the tailnet, restrict access with Tailscale access controls
- On WSL, interop makes pi-web access equal to the Windows user's access.
- **To remove everything:**
  1. `cf-tunnel.sh disable`
  2. `ts.sh off`
  3. `service.sh uninstall`. On WSL, also run `register-task.ps1 -LinuxUser <user> -Remove` elevated.
  4. Delete the tunnel and the Access app in the dashboard, and the `own` device in Tailscale.
