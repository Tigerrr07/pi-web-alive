#!/bin/bash
# status.sh — one-screen health check of pi-web, tmux, Tailscale and Cloudflare.
# Run as the pi-web user. Read-only.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE — run setup.sh first"; exit 1; }
PORT=$(env_get PORT); PORT="${PORT:-30141}"
MODE=$(env_get TS_MODE); MODE="${MODE:-none}"
HOSTS=$(env_get ALLOWED_HOSTS); CFH=$(env_get CF_HOSTNAME); CFO=$(env_get CF_OTHER_HOSTNAMES)
code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1"; }

echo "user/os:     $(id -un) / $(os_kind)"
echo "config:      PORT=$PORT TS_MODE=$MODE ALLOWED_HOSTS=${HOSTS:-<none>} CF_HOSTNAME=${CFH:-<none>}"
echo "password:    $([ -s "$PASS_FILE" ] && echo "set ($(ls -l "$PASS_FILE" | cut -c1-10))" || echo 'MISSING -> keep-alive refuses to start')"
echo "keep-alive:  $(keepalive_pids | wc -l | tr -d ' ') running (should be 1)"
echo "tmux:        $(tmux ls 2>/dev/null | grep '^piweb:' || echo 'no piweb session')"
echo "pi-web:      HTTP $(code "http://127.0.0.1:$PORT/")  (307 = login page, 200 = NO password, 000 = down)"
echo "auth:        API without login -> $(code "http://127.0.0.1:$PORT/api/sessions")  (401 = protected)"
if ss -ltn 2>/dev/null | grep -qE "0\.0\.0\.0:$PORT |\[::\]:$PORT |\*:$PORT "; then
  echo "!! pi-web listens on ALL interfaces — it must be 127.0.0.1 only"
fi

case "$MODE" in system|own|windows)
  [ "$MODE" = own ] && echo "tailscaled:  $(pgrep -u "$(id -u)" -x tailscaled >/dev/null && echo running || echo stopped) (userspace)"
  echo "tailscale:   $(ts_cli "$MODE" status 2>&1 | head -n 1)"
  ts_cli "$MODE" serve status 2>&1 | tr -d '\r' | sed '/^$/d; s/^/             /'
  for h in ${HOSTS//,/ }; do case "$h" in *.ts.net)
    echo "tailnet URL: https://$h/login -> $(code "https://$h/login" 15)  (200 = reachable; needs this machine on the tailnet)" ;;
  esac; done ;;
esac

if [ -n "$CFH" ]; then
  echo "cloudflare:  cloudflared=$(pgrep -u "$(id -u)" -x cloudflared >/dev/null && echo running || echo stopped)  token=$([ -s "$TOKEN_FILE" ] && echo present || echo MISSING)"
  for h in $CFH ${CFO//,/ }; do
    r=$(probe "$h")
    if is_access_redirect "$r"; then a=protected; else a="NOT PROTECTED (${r%%\?*})"; fi
    echo "             https://$h  access=$a"
  done
fi
echo "log:";  tail -n 4 "$LOG" 2>/dev/null | sed 's/^/             /'
