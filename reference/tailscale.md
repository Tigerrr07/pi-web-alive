# Remote access via Tailscale

Only devices signed in to your tailnet can reach pi-web. Tailscale issues the HTTPS certificate, and the pi-web password still applies. By default that means **every** device in the tailnet, including other users' devices. If the tailnet is shared, restrict who can reach this device with Tailscale access controls (grants/ACLs). `$S` is this skill's `scripts/` directory.

## Choose a mode

| Machine | Mode | The user does first |
|---|---|---|
| Linux | `system` | `sudo tailscale up`, then `sudo tailscale set --operator=$USER` (allows `serve` without root) |
| macOS | `system` | Log in to the Tailscale app (Standalone variant). The CLI integration is optional; the scripts fall back to the app's CLI |
| WSL, with Tailscale on Windows | `windows` | Log in on Windows, then run `tailscale.exe set --unattended` so it stays online without a Windows login |
| WSL, or Linux without root, with its own device name | `own` | `bash $S/ts.sh install`, then `bash $S/ts.sh up <device-name>`. Open the link and log in with the same account as the devices you'll connect from |

## Publish

```bash
bash $S/ts.sh serve          # auto-detects the mode; or: ts.sh serve system|windows|own
bash $S/service.sh restart   # normal terminal; makes pi-web accept the new hostname
```

- **What `serve` does:** it runs `tailscale serve --bg <PORT>`, saves `TS_MODE` and adds `<device>.<tailnet>.ts.net` to `ALLOWED_HOSTS`.
- **"Serve is not enabled on your tailnet":** the user opens the printed link.
- **To connect from a phone or another computer:** sign in to Tailscale there with the same account, open `https://<device>.<tailnet>.ts.net`, then enter the pi-web password.

## How the modes behave

- **`system` and `own`:** the watchdog restores serve if it gets cleared, for example after you log in to Tailscale again.
- **`own` only:** the watchdog also starts the userspace tailscaled. On WSL, it adds `TS_DEBUG_MTU=1180`.
- **`windows`:**
  - The serve config lives in the Windows app, and only one service can use port 443.
  - WSL2 forwards Windows' localhost into WSL, so the app can proxy `127.0.0.1:<PORT>`.
  - If Windows Tailscale was logged out, run `ts.sh serve windows` again.
- **Turn it off:** `ts.sh off` stops serving, sets `TS_MODE=none` and removes the name it added from `ALLOWED_HOSTS`. In `own` mode, also remove the device in the Tailscale admin console.
