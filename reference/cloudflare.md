# Remote access via Cloudflare Tunnel + Access

This works from any browser and needs no app. A request has to pass Cloudflare Access before it reaches the pi-web password. `$S` is this skill's `scripts/` directory.

**Fail closed.** Before every cloudflared start, and every 10 minutes while it runs, the watchdog checks `https://<CF_HOSTNAME>/`. The tunnel runs only while that URL returns a `302` to `<team>.cloudflareaccess.com`. If Access is missing, deleted or unreachable, the tunnel stops.

**Needs:** a domain on Cloudflare (the free Zero Trust plan is enough), and `cloudflared` on `PATH` or in `~/.local/bin`.

## Steps

1. **Access app first** (user). Go to Zero Trust → Access → Applications → Add → **Self-hosted**:
   - Domain: `piweb.<domain>`.
   - Policy: **Allow**, Include **Emails** = the user's own email. Never use `Everyone`, a whole email domain or `Bypass`.
   - Login: One-time PIN, or GitHub/Google with MFA.
   - Session duration: 8 hours or less.
2. **Tunnel** (user). Go to Networking → Tunnels → Create Tunnel (older dashboard: Zero Trust → Networks → Tunnels) and choose type Cloudflared. The install command on the page contains the token, which starts with `eyJ`. Don't run that command.
3. **Save the token.** The user runs this in their own terminal and pastes into the hidden prompt. Pasting the whole install command also works.
   ```bash
   bash $S/cf-tunnel.sh setup piweb.<domain>
   ```
4. **Temporary connector.** The dashboard needs a connector online before it lets you add a route. Run:
   ```bash
   nohup bash $S/cf-tunnel.sh connect 10 >/dev/null 2>&1 &
   ```
   It runs only while the hostname can't be reached yet, or is already behind Access. It exits after 10 minutes.
5. **Route** (user). Go to Add route → Published application:
   - Subdomain `piweb`, your domain, Path empty.
   - Service URL `http://127.0.0.1:<PORT>`, including `http://`.
   - Recommended: under Additional application settings → Access, turn on **Protect with Access**. Enter the team name and the AUD tag from the Access app's Additional settings, then press **Enter**.
6. **Start.** `bash $S/cf-tunnel.sh check` should print `OK`. Then the user runs `bash $S/service.sh restart` in a normal terminal. This starts cloudflared and adds `CF_HOSTNAME` to the host allow-list.
7. **Verify.**
   - `status.sh` shows `cloudflared=running access=protected`.
   - On a device without Tailscale, open the hostname: the Cloudflare login comes first, then the pi-web password.
   - `curl -sI https://piweb.<domain>/` returns `302` to `cloudflareaccess.com`.

## Notes

- **Which pi-web is exposed:** the Service URL port decides, because all users on a machine share loopback.
- **Several hostnames on one tunnel:** register them with `cf-tunnel.sh others h1,h2`. Every one must be behind Access, or the watchdog stops the tunnel.
- **Review logins** in Zero Trust → Logs → Access.
- **To remove it:** run `cf-tunnel.sh disable`, then `service.sh restart`. Then delete the route, the tunnel and the Access app in the dashboard.
