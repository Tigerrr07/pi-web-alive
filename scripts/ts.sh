#!/bin/bash
# ts.sh — publish pi-web on your tailnet with `tailscale serve` (HTTPS, tailnet only;
# never `funnel`). Run as the pi-web user, after setup.sh.
#
#   ts.sh serve [system|own|windows]  https://<device>.<tailnet>.ts.net -> 127.0.0.1:PORT,
#                                     saves TS_MODE and adds the name to ALLOWED_HOSTS
#   ts.sh install                     (own) download tailscale + tailscaled to ~/.local/bin (Linux/WSL)
#   ts.sh up <device-name>            (own) start the userspace tailscaled, print the login link
#   ts.sh status
#   ts.sh off                         stop serving pi-web, TS_MODE=none
#
# Modes: system  = this machine's Tailscale (Linux daemon / macOS app)
#        windows = WSL: the Windows Tailscale app (Windows forwards localhost to WSL)
#        own     = a separate userspace device for this user (no root, own name)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
BIN="$HOME/.local/bin"
SOCK="$TS_DIR/tailscaled.sock"

auto_mode() {
  local m; m=$(env_get TS_MODE)
  case "$m" in system|own|windows) echo "$m"; return ;; esac
  case "$(os_kind)" in
    macos) echo system ;;
    wsl) if [ -x "$BIN/tailscale" ]; then echo own
         elif [ -x "$WIN_TS" ]; then echo windows
         elif command -v tailscale >/dev/null; then echo system
         else echo own; fi ;;
    *) if command -v tailscale >/dev/null || [ ! -x "$BIN/tailscale" ]; then echo system; else echo own; fi ;;
  esac
}

start_own_daemon() {
  [ -x "$BIN/tailscaled" ] || { echo "no $BIN/tailscaled — run: ts.sh install" >&2; exit 1; }
  mkdir -p "$TS_DIR"
  pgrep -u "$(id -u)" -x tailscaled >/dev/null && return 0
  local mtu=
  # WSL's eth0 MTU is 1280: default WireGuard packets don't fit and TLS handshakes stall
  [ "$(os_kind)" = wsl ] && mtu=1180
  env ${mtu:+TS_DEBUG_MTU=$mtu} nohup "$BIN/tailscaled" --tun=userspace-networking \
    --statedir="$TS_DIR" --socket="$SOCK" >>"$TS_DIR/tailscaled.log" 2>&1 </dev/null &
  sleep 4
}

not_logged_in_help() {
  echo "Tailscale ($1) is not running or not logged in:" >&2
  case "$1" in
    system) case "$(os_kind)" in
              macos) echo "  open the Tailscale app and log in (Standalone variant recommended)" >&2 ;;
              *)     echo "  sudo tailscale up          # then open the printed link" >&2 ;;
            esac ;;
    windows) echo "  log in with the Tailscale app on Windows (and enable Run unattended)" >&2 ;;
    own)     echo "  ts.sh up <device-name>     # then open the printed link" >&2 ;;
  esac
}

case "${1:-}" in
serve)
  MODE="${2:-$(auto_mode)}"
  PORT=$(env_get PORT); [ -n "$PORT" ] || { echo "no PORT in $ENV_FILE — run setup.sh first" >&2; exit 1; }
  case "$MODE" in
    own) [ -x "$BIN/tailscale" ] || { echo "run: ts.sh install && ts.sh up <device-name>" >&2; exit 1; }
         start_own_daemon ;;
    windows) [ "$(os_kind)" = wsl ] && [ -x "$WIN_TS" ] ||
               { echo "windows mode needs WSL + Tailscale installed on Windows" >&2; exit 1; } ;;
    system) ts_cli system version >/dev/null 2>&1 || {
              echo "tailscale CLI not found on PATH (macOS: $MAC_TS is used if present)" >&2; exit 1; } ;;
    *) echo "mode must be system|own|windows" >&2; exit 2 ;;
  esac
  ts_cli "$MODE" status >/dev/null 2>&1 || { not_logged_in_help "$MODE"; exit 1; }
  DNS=$(ts_dnsname "$MODE")
  [ -n "$DNS" ] || { echo "could not read this device's DNS name (is MagicDNS on?)" >&2; exit 1; }
  echo "== tailscale serve --bg $PORT   (mode $MODE, device $DNS)"
  echo "   (first time: if it prints 'Serve is not enabled on your tailnet', open that link)"
  if ! ts_cli "$MODE" serve --bg "$PORT"; then
    if [ "$MODE" = system ] && [ "$(os_kind)" != macos ]; then
      echo "!! On Linux allow your user to manage Tailscale once:  sudo tailscale set --operator=$(id -un)" >&2
    fi
    exit 1
  fi
  OLD_HOSTS=$(env_get ALLOWED_HOSTS); OLD_MODE=$(env_get TS_MODE)
  env_set TS_MODE "$MODE"
  env_set ALLOWED_HOSTS "$(list_add "$OLD_HOSTS" "$DNS")"
  env_set TS_HOSTNAME "$DNS"    # remembered so `ts.sh off` removes exactly this name again
  echo
  echo "pi-web URL:  https://$DNS    (password: cat $PASS_FILE)"
  if [ "$(env_get ALLOWED_HOSTS)" != "$OLD_HOSTS" ] || [ "$MODE" != "$OLD_MODE" ]; then
    echo "Config changed -> restart from a normal terminal (not inside pi-web):  bash $DIR/service.sh restart"
  fi
  ;;
install)
  [ "$(uname -s)" = Linux ] || { echo "own mode is for Linux/WSL; on macOS use the Tailscale app (system)" >&2; exit 1; }
  case "$(uname -m)" in x86_64) A=amd64 ;; aarch64|arm64) A=arm64 ;; *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; esac
  V=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | tr -d '\n' |
      sed -n 's/.*"TarballsVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$V" ] || { echo "could not find the latest version" >&2; exit 1; }
  T="tailscale_${V}_${A}.tgz"
  D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
  curl -fsSL "https://pkgs.tailscale.com/stable/$T" -o "$D/$T"
  echo "$(curl -fsSL "https://pkgs.tailscale.com/stable/$T.sha256")  $D/$T" | sha256sum -c -
  tar xzf "$D/$T" -C "$D"
  mkdir -p "$BIN" "$TS_DIR"
  install -m 755 "$D/tailscale_${V}_${A}/tailscale" "$D/tailscale_${V}_${A}/tailscaled" "$BIN/"
  "$BIN/tailscale" version | head -1
  echo "Next: ts.sh up <device-name>"
  ;;
up)
  NAME="${2:?usage: ts.sh up <device-name>   e.g. $(id -un)-piweb}"
  [ -x "$BIN/tailscale" ] || { echo "run: ts.sh install" >&2; exit 1; }
  start_own_daemon
  if ts_cli own status >/dev/null 2>&1; then
    echo "already logged in:"; ts_cli own status | head -1
  else
    echo "Open this link and log in with the SAME Tailscale account as the devices you'll connect from:"
    timeout 25 "$BIN/tailscale" --socket="$SOCK" up --hostname="$NAME" 2>&1 |
      grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' | head -1 || true
  fi
  echo "Then: ts.sh serve own"
  ;;
status)
  MODE=$(env_get TS_MODE); MODE="${MODE:-none}"
  echo "TS_MODE:     $MODE    ALLOWED_HOSTS=$(env_get ALLOWED_HOSTS)"
  [ "$MODE" = none ] && exit 0
  [ "$MODE" = own ] && echo "tailscaled:  $(pgrep -u "$(id -u)" -x tailscaled >/dev/null && echo running || echo stopped)"
  ts_cli "$MODE" status 2>&1 | head -3 || true
  ts_cli "$MODE" serve status 2>&1 || true
  ;;
off)
  MODE=$(env_get TS_MODE)
  # The name `serve` added to ALLOWED_HOSTS (older setups didn't record it: ask Tailscale)
  H=$(env_get TS_HOSTNAME)
  case "$MODE" in system|own|windows) [ -n "$H" ] || H=$(ts_dnsname "$MODE") ;; esac
  env_set TS_MODE none          # the running keep-alive sees this and stops re-serving
  case "$MODE" in
    own) ts_cli own serve reset && echo "serve reset on own device" || true ;;
    system|windows) ts_cli "$MODE" serve --https=443 off && echo "stopped serving https:443" || true ;;
    *) echo "TS_MODE was ${MODE:-none}: nothing to turn off" ;;
  esac
  if [ -n "$H" ]; then
    OLD_HOSTS=$(env_get ALLOWED_HOSTS)
    env_set ALLOWED_HOSTS "$(list_remove "$OLD_HOSTS" "$H")"
    [ "$(env_get ALLOWED_HOSTS)" != "$OLD_HOSTS" ] && echo "removed $H from ALLOWED_HOSTS"
  elif [ "$MODE" != none ] && [ -n "$MODE" ]; then
    echo "could not tell which Tailscale name to remove; check ALLOWED_HOSTS in $ENV_FILE"
  fi
  env_set TS_HOSTNAME ""
  echo "Takes full effect at the next restart (no hurry, serving is already off): bash $DIR/service.sh restart"
  ;;
*) sed -n '2,15p' "$0"; exit 2 ;;
esac
