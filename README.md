# pi-web-alive

English | [中文](README_CN.md)

**One-line setup.** On the machine that should run pi-web, tell your AI agent (Claude Code, pi, …):

```text
Set up pi-web on this machine with https://github.com/Tigerrr07/pi-web-alive
```

---

Keep [pi-web](https://github.com/agegr/pi-web) (the browser UI for the pi coding agent) running in tmux on Linux, WSL2 or macOS, and reach it from your phone or other computers:

- **Tailscale**: private HTTPS inside your tailnet, for devices that run Tailscale.
- **Cloudflare Tunnel + Access**: a public hostname that works from any browser, behind Cloudflare Access. The tunnel stops automatically if Access is not in front of it.

It is an [Agent Skill](https://agentskills.io/specification): `SKILL.md` holds the full instructions, and `scripts/` does the work. You can use it through an AI agent or run the scripts yourself.

## Requirements

- ≥ 4 GB RAM. Smaller machines run out of memory during the first start or while the agent works, and can stop responding
- Node ≥ 22.19
- tmux ≥ 3.0
- curl
- a C/C++ toolchain (for node-pty)
- the pi coding agent:

  ```bash
  npm i -g @earendil-works/pi-coding-agent
  ```

- For remote access: Tailscale and/or cloudflared, plus a domain on Cloudflare.

## Quick start with an AI agent

Use the one line at the top of this page. You can add what you need, for example: *"…and make it reachable from my phone over Tailscale."*

The agent installs the skill and does the work. It hands you only the steps that need you:
- Tailscale login links
- the Cloudflare dashboard
- pasting the tunnel token
- anything that needs sudo or an elevated PowerShell

Once the skill is installed, later requests don't need the link. For example: *"Check pi-web's status"* or *"Add Cloudflare access to pi-web."*

### Instructions for the AI agent

If a user asks you to use this repository:

1. **Install the skill.** Put the repository in your skills directory and keep the folder name `pi-web-alive`:
   - Claude Code: `~/.claude/skills/pi-web-alive`
   - pi: `~/.pi/agent/skills/pi-web-alive`
   - other Agent Skills agents: `~/.agents/skills/pi-web-alive`

   ```bash
   git clone https://github.com/Tigerrr07/pi-web-alive ~/.claude/skills/pi-web-alive

   # without git (fresh servers often don't have it):
   mkdir -p ~/.claude/skills && curl -fsSL https://github.com/Tigerrr07/pi-web-alive/archive/refs/heads/main.tar.gz \
     | tar xz -C ~/.claude/skills && mv ~/.claude/skills/pi-web-alive-main ~/.claude/skills/pi-web-alive
   ```

   If the folder already exists, update it with `git pull` instead.
2. **Follow the skill.** Read `SKILL.md` in that folder and follow it. Run the scripts from its `scripts/` directory.
3. **Missing prerequisites.** Tell the user what is missing. Install it only with their permission.

### Install the skill yourself (optional)

```bash
git clone https://github.com/Tigerrr07/pi-web-alive ~/.claude/skills/pi-web-alive   # or ~/.pi/agent/skills/, ~/.agents/skills/
```

In pi you can load it explicitly with `/skill:pi-web-alive`. To try it once without installing, run `pi --skill ./pi-web-alive`.

## Use it by hand (Linux)

```bash
git clone https://github.com/Tigerrr07/pi-web-alive ~/pi-web-alive
S=~/pi-web-alive/scripts

bash $S/setup.sh --port 30141     # config, password, watchdog
bash $S/service.sh install        # systemd --user unit + linger: starts at boot
bash $S/status.sh                 # expect: pi-web HTTP 307, API 401

# Tailscale (log in first: sudo tailscale up; sudo tailscale set --operator=$USER)
bash $S/ts.sh serve
bash $S/service.sh restart        # from a normal terminal, not inside pi-web

cat ~/.config/pi-web/password     # the pi-web login password
```

Then open `https://<machine>.<tailnet>.ts.net` on any device signed in to your tailnet.

More: [SKILL.md](SKILL.md) (macOS, WSL, day-to-day), [Tailscale modes](reference/tailscale.md), [Cloudflare](reference/cloudflare.md), [troubleshooting](reference/troubleshooting.md).

## Turn it off / on

```bash
bash <skill>/scripts/service.sh stop        # off, and stays off after a reboot
bash <skill>/scripts/service.sh start       # on again
bash <skill>/scripts/service.sh uninstall   # remove the autostart (config is kept)
```

Run these in a normal terminal, not inside pi-web. Or just tell your agent: *"turn pi-web off"*.

## Update

```bash
git -C ~/.pi/agent/skills/pi-web-alive pull   # or wherever you cloned it
bash <clone>/scripts/setup.sh                 # re-installs ~/bin/piweb-keepalive.sh, keeps your config
bash <clone>/scripts/service.sh restart       # from a normal terminal
```

## Where things live

Nothing secret is stored in the repository. Per-user state lives here:

- `~/.config/pi-web/`: `env`, `password`, `cf-token`
- `~/bin/piweb-keepalive.sh`: the watchdog
- `~/.cache/piweb-keepalive.log`: the log

## Security

pi-web can run any command as your user. This project:

- requires a password
- binds pi-web to `127.0.0.1`
- publishes it only through `tailscale serve` or an Access-protected tunnel

Never use `tailscale funnel`, router port forwarding or `0.0.0.0`.

## Tested on

**WSL2 on Windows** (Ubuntu 26.04, Node 24 via nvm, tmux 3.6):
- setup, the watchdog and crash recovery, `status.sh`
- Task Scheduler `start` / `stop` / `restart`, with a test task: a stopped task stays off while its trigger keeps firing
- the Cloudflare Access check: a protected hostname is accepted, an unprotected one is refused (fail-closed)

**Linux on AWS EC2** (RHEL 10.2, x86_64, 2 vCPU, 7.5 GB RAM, system Node 22, no nvm):
- Claude Code set everything up from the skill alone, given a one-sentence request
- recovery after a crash, a killed tmux session and `service.sh restart`
- back after a reboot without anyone logging in
- `stop` stays off across a reboot; `start` brings it back
- Tailscale (`system` mode): HTTPS from another device, password required, serve restored automatically after being cleared, reachable again 25s after a reboot

**Not tested yet:** macOS, and a full Cloudflare Tunnel run with this repository.
