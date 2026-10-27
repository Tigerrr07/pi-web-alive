#!/bin/bash
# piweb-keepalive.sh — installed as ~/bin/piweb-keepalive.sh by setup.sh.
# Runs pi-web in tmux session "piweb" (restarted 5s after it exits), recreates the
# session if it disappears, and keeps the remote entry points up:
#   * Tailscale: `tailscale serve --bg <PORT>` (and the user's own tailscaled if TS_MODE=own)
#   * Cloudflare Tunnel: cloudflared, ONLY while every hostname is behind Cloudflare Access
# Never exits. Started by systemd --user (Linux), launchd (macOS) or Task Scheduler (WSL).
# Self-contained and bash 3.2 compatible (macOS).
#
# ~/.config/pi-web/env (written by setup.sh / ts.sh / cf-tunnel.sh):
#   PORT=30141                      pi-web port, bound to 127.0.0.1 only
#   ALLOWED_HOSTS=a.tailX.ts.net    extra hostnames pi-web accepts (comma-separated)
#   TS_MODE=none|system|own|windows
#       system   this machine's Tailscale (Linux tailscaled / macOS app): keep serve on
#       own      this user's userspace tailscaled in ~/.local/bin (no root): start it + serve
#       windows  WSL: the Windows Tailscale app serves the port (ts.sh serve, once)
#   CF_HOSTNAME=piweb.example.com   Cloudflare Tunnel hostname of this pi-web
#   CF_OTHER_HOSTNAMES=x.example.com,...  other hostnames the same tunnel publishes
# ~/.config/pi-web/password  required (no password -> refuse to start)
# ~/.config/pi-web/cf-token  optional Cloudflare Tunnel token

CONF_DIR="$HOME/.config/pi-web"
[ -f "$CONF_DIR/env" ] && . "$CONF_DIR/env"
PORT="${PORT:-30141}"
TS_MODE="${TS_MODE:-none}"
SESSION=piweb
LOG="$HOME/.cache/piweb-keepalive.log"
mkdir -p "$HOME/.cache"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Services don't read ~/.bashrc / ~/.zshrc: build PATH ourselves (newest nvm Node first)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
NODE_BIN=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -n 1)
[ -n "$NODE_BIN" ] && export PATH="$NODE_BIN:$PATH"
export TAILSCALE_BE_CLI=1   # macOS app binary: act as the CLI, don't open the GUI
export PI_WEB_ALLOWED_HOSTS="${ALLOWED_HOSTS:-}${CF_HOSTNAME:+${ALLOWED_HOSTS:+,}$CF_HOSTNAME}"

# Fail closed: pi-web is a remote shell. Without a password it lets anyone in, and
# on 127.0.0.1 it prints no warning while Tailscale/Cloudflare still publish it.
if [ ! -s "$CONF_DIR/password" ]; then
  echo "[$(date '+%F %T')] REFUSING to start pi-web: $CONF_DIR/password is missing or empty" | tee -a "$LOG" >&2
  exit 1
fi
export PI_WEB_PASSWORD="$(cat "$CONF_DIR/password")"

# ---------------------------------------------------------------- pi-web in tmux
# -y: otherwise npx stops at "Ok to proceed? (y)" whenever a new version ships.
# -H 127.0.0.1: never listen on the LAN, whatever PI_WEB_HOSTNAME says.
RUN_LOOP='while true; do
  npx -y @agegr/pi-web@latest --no-open -H 127.0.0.1 -p '"$PORT"'
  rc=$?
  echo "[$(date "+%F %T")] pi-web exited (code $rc), restarting in 5s" | tee -a "'"$LOG"'"
  sleep 5
done'

start_session() {
  # -e: a tmux server that is already running would not inherit our exports
  tmux new-session -d -s "$SESSION" -c "$HOME" \
    -e "PATH=$PATH" -e "PI_WEB_ALLOWED_HOSTS=$PI_WEB_ALLOWED_HOSTS" \
    -e "PI_WEB_PASSWORD=$PI_WEB_PASSWORD" \
    bash -c "$RUN_LOOP" && log "started tmux session $SESSION (127.0.0.1:$PORT)"
}

# ------------------------------------------------------------------- Tailscale
TS_DIR="$HOME/.local/share/tailscale"
case "$TS_MODE" in
  own) TS_CMD=("$HOME/.local/bin/tailscale" "--socket=$TS_DIR/tailscaled.sock") ;;
  system)
    if command -v tailscale >/dev/null 2>&1; then TS_CMD=(tailscale)
    else TS_CMD=(/Applications/Tailscale.app/Contents/MacOS/Tailscale); fi ;;
  *) TS_CMD=() ;;
esac

start_tailscaled() {    # TS_MODE=own only: the user's own userspace node (no root)
  [ "$TS_MODE" = own ] && [ -x "$HOME/.local/bin/tailscaled" ] || return 0
  pgrep -u "$(id -u)" -x tailscaled >/dev/null && return 0
  mkdir -p "$TS_DIR"
  local mtu=
  # WSL's eth0 MTU is 1280: default WireGuard packets don't fit and TLS handshakes stall
  grep -qi microsoft /proc/version 2>/dev/null && mtu=1180
  env ${mtu:+TS_DEBUG_MTU=$mtu} "$HOME/.local/bin/tailscaled" --tun=userspace-networking \
    --statedir="$TS_DIR" --socket="$TS_DIR/tailscaled.sock" >>"$TS_DIR/tailscaled.log" 2>&1 &
  log "started userspace tailscaled${mtu:+ (MTU $mtu)}"
}

ts_next=0 ts_warned=
ensure_serve() {        # once the node is logged in, publish pi-web on https://<node>/
  [ ${#TS_CMD[@]} -gt 0 ] || return 0
  local now out rc pid w
  # `ts.sh off` changed TS_MODE in the file: stop re-serving right away (no restart needed)
  [ "$(sed -n 's/^TS_MODE=//p' "$CONF_DIR/env" 2>/dev/null | tail -n 1)" = "$TS_MODE" ] || return 0
  "${TS_CMD[@]}" status >/dev/null 2>&1 || return 0          # not running / not logged in yet
  "${TS_CMD[@]}" serve status 2>/dev/null | grep -q "127.0.0.1:$PORT" && { ts_warned=; return 0; }
  now=$(date +%s); [ "$now" -lt "$ts_next" ] && return 0
  ts_next=$((now + 600))                                      # failures: retry every 10 min
  out=$(mktemp)
  # macOS has no `timeout`; serve may wait forever if Serve isn't enabled on the tailnet
  "${TS_CMD[@]}" serve --bg "$PORT" </dev/null >"$out" 2>&1 &
  pid=$!; ( sleep 20; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$pid"; rc=$?; kill "$w" 2>/dev/null
  if [ $rc = 0 ]; then
    log "tailscale serve -> 127.0.0.1:$PORT"; ts_warned='' ts_next=0
  elif [ -z "$ts_warned" ]; then
    log "tailscale serve failed (rc $rc): $(tr '\n' ' ' < "$out" | cut -c1-300)"; ts_warned=1
  fi
  rm -f "$out"
}

# ---------------------------------------------------------- Cloudflare Tunnel
# Fail closed: cloudflared runs only while https://<host>/ answers with a Cloudflare
# Access login redirect for CF_HOSTNAME *and* every CF_OTHER_HOSTNAMES entry, checked
# before every start and every 10 minutes while running.
CF_TOKEN_FILE="$CONF_DIR/cf-token"
cf_next=0 cf_blocked=0 cf_bad=
access_ok_host() {
  local h=$1 r
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  r=$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "https://$h/" 2>/dev/null)
  # Home routers cache NXDOMAIN for a new hostname; ask Cloudflare's resolver directly
  case "$r" in ""|000*)
    r=$(curl -s -o /dev/null --max-time 15 --doh-url https://1.1.1.1/dns-query \
      -w '%{http_code} %{redirect_url}' "https://$h/" 2>/dev/null) ;;
  esac
  [[ "$r" =~ ^302\ https://[A-Za-z0-9-]+\.cloudflareaccess\.com/ ]]
}
access_ok() {
  local h
  for h in $CF_HOSTNAME ${CF_OTHER_HOSTNAMES//,/ }; do
    access_ok_host "$h" || { cf_bad=$h; return 1; }
  done
}
ensure_cloudflared() {
  [ -n "${CF_HOSTNAME:-}" ] && [ -s "$CF_TOKEN_FILE" ] || return 0
  command -v cloudflared >/dev/null || return 0
  local now running=0
  now=$(date +%s)
  pgrep -u "$(id -u)" -x cloudflared >/dev/null && running=1
  [ $running = 1 ] && [ "$now" -lt "$cf_next" ] && return 0
  cf_next=$((now + 600))
  if ! access_ok; then
    [ $running = 1 ] && pkill -u "$(id -u)" -x cloudflared
    if [ $running = 1 ] || [ $cf_blocked = 0 ]; then
      log "cloudflared NOT running: $cf_bad is not behind Cloudflare Access"
    fi
    cf_blocked=1                # not running -> re-checked every loop (30s)
    return 0
  fi
  cf_blocked=0
  [ $running = 1 ] && return 0
  # Token via env, not argv, so it never shows up in `ps`
  TUNNEL_TOKEN="$(cat "$CF_TOKEN_FILE")" cloudflared --no-autoupdate tunnel run \
    >>"$HOME/.cache/cloudflared.log" 2>&1 &
  log "started cloudflared for https://$CF_HOSTNAME${CF_OTHER_HOSTNAMES:+ (also checked: $CF_OTHER_HOSTNAMES)}"
}

# ---------------------------------------------------------------- main loop
# Stopping the service stops the tunnel too (tmux is removed by the service manager / service.sh)
trap 'pkill -P $$ -x cloudflared 2>/dev/null; log "keep-alive stopped (pid $$)"; exit 0' TERM INT HUP

log "keep-alive started (pid $$, port $PORT, TS_MODE=$TS_MODE${CF_HOSTNAME:+, CF_HOSTNAME=$CF_HOSTNAME})"
while true; do
  start_tailscaled
  ensure_serve
  ensure_cloudflared
  tmux has-session -t "$SESSION" 2>/dev/null || start_session
  sleep 30 & wait $!
done
