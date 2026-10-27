#!/bin/bash
# setup.sh — run as the user who will own pi-web (Linux / WSL / macOS).
# Checks prerequisites, writes ~/.config/pi-web/env, creates the password and
# installs ~/bin/piweb-keepalive.sh. Safe to re-run (keeps existing values).
#
#   setup.sh [--port 30141] [--ts-mode none|system|own|windows] [--allowed-hosts h1,h2]
#
# Next: service.sh install (autostart), then ts.sh serve and/or cf-tunnel.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

PORT="" MODE="" ALLOWED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --ts-mode) MODE="$2"; shift 2 ;;
    --allowed-hosts) ALLOWED="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
PORT="${PORT:-$(env_get PORT)}"; PORT="${PORT:-30141}"
MODE="${MODE:-$(env_get TS_MODE)}"; MODE="${MODE:-none}"
case "$PORT" in ''|*[!0-9]*) echo "--port must be a number" >&2; exit 2 ;; esac
case "$MODE" in none|system|own|windows) ;; *) echo "--ts-mode must be none|system|own|windows" >&2; exit 2 ;; esac

echo "== $(id -un) on $(os_kind)"
ok=1
for c in node npx tmux curl pi; do
  printf '   %-5s %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done
command -v npx >/dev/null || { echo "!! Node.js/npx missing (need Node >= 22.19)" >&2; ok=0; }
if command -v node >/dev/null && ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)'; then
  echo "!! Node $(node -v) is too old: pi-web needs >= 22.19" >&2; ok=0
fi
if ! command -v tmux >/dev/null; then echo "!! tmux missing" >&2; ok=0
else
  tv=$(tmux -V | sed 's/[^0-9.]//g'); [ "${tv%%.*}" -ge 3 ] 2>/dev/null ||
    { echo "!! tmux $tv is too old: need >= 3.0 (new-session -e)" >&2; ok=0; }
fi
command -v curl >/dev/null || { echo "!! curl missing" >&2; ok=0; }
command -v pi >/dev/null || echo "   (pi not installed: npm i -g @earendil-works/pi-coding-agent — pi-web needs it to run models)"
[ $ok = 1 ] || exit 1

# >= 4 GB RAM: smaller machines run out of memory on the first start or while the agent works
if [ "$(uname -s)" = Darwin ]; then mem_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
else mem_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 )); fi
if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 3800 ]; then
  echo "!! only ${mem_mb} MB RAM: pi-web needs >= 4 GB (it may run out of memory and hang the machine)" >&2
fi

# Port already taken by something else?
if command -v ss >/dev/null; then busy=$(ss -ltn 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" || true)
else busy=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true); fi
[ -n "$busy" ] && echo "NOTE: port $PORT is in use (fine if it is this user's running pi-web; otherwise use --port)"

mkdir -p "$HOME/bin" "$CONF_DIR" "$HOME/.cache"; chmod 700 "$CONF_DIR"

install -m 755 "$DIR/piweb-keepalive.sh" "$KEEPALIVE"
bash -n "$KEEPALIVE"
echo "== installed $KEEPALIVE"

env_set PORT "$PORT"
env_set TS_MODE "$MODE"
[ -n "$ALLOWED" ] && env_set ALLOWED_HOSTS "$ALLOWED"

if [ ! -s "$PASS_FILE" ]; then
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)
  [ ${#pw} = 24 ] || { echo "could not generate a password" >&2; exit 1; }
  (umask 077; printf '%s\n' "$pw" > "$PASS_FILE"); unset pw
  echo "== created password file $PASS_FILE (600)"
fi
chmod 600 "$PASS_FILE"

echo "== $ENV_FILE:"; sed 's/^/   /' "$ENV_FILE"
echo
echo "Next:"
echo "  1. bash $DIR/service.sh install      # start at boot/login, keep running"
echo "  2. bash $DIR/ts.sh serve              # Tailscale (tailnet only)"
echo "     bash $DIR/cf-tunnel.sh setup <hostname>   # and/or Cloudflare Tunnel + Access (any browser)"
echo "  Password: cat $PASS_FILE"
