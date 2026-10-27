#!/bin/bash
# cf-tunnel.sh — remote access to pi-web from any browser (phone, other computers; no
# client app needed) through a Cloudflare Tunnel guarded by Cloudflare Access.
# Run as the pi-web user.
#
#   cf-tunnel.sh setup <hostname>     save the tunnel token (hidden prompt or $CF_TOKEN), set CF_HOSTNAME
#   cf-tunnel.sh connect [minutes]    temporary connector for the dashboard wizard (default 10)
#   cf-tunnel.sh others <h1,h2>|none  other hostnames the same tunnel publishes (all must be behind Access)
#   cf-tunnel.sh check [hostname]     is it behind Cloudflare Access?
#   cf-tunnel.sh status
#   cf-tunnel.sh disable              stop cloudflared, forget token + hostnames
#
# Never pass the token as an argument (it would show up in `ps` and shell history).
# Fail closed: the keep-alive only runs cloudflared while https://<hostname>/ answers with
# a Cloudflare Access login redirect (re-checked every 10 minutes).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
CF_LOG="$HOME/.cache/cloudflared.log"

access_check() {   # prints the probe result, succeeds only behind Access
  local r; r=$(probe "$1")
  echo "   https://$1/ -> ${r%%\?*}"
  is_access_redirect "$r"
}
perm() { ls -l "$1" | cut -c1-10; }
valid_token() {   # base64 JSON with account (a), tunnel id (t) and secret (s)
  [[ "$1" =~ ^eyJ[A-Za-z0-9_=+/-]{40,}$ ]] || return 1
  python3 -c 'pass' 2>/dev/null || return 0      # no usable python3 (e.g. bare macOS)
  python3 -I -c 'import base64,json,sys
t=sys.argv[1]; d=json.loads(base64.b64decode(t+"="*(-len(t)%4)))
assert {"a","t","s"} <= d.keys()' "$1" 2>/dev/null
}

case "${1:-}" in
setup)
  HOST="${2:?usage: cf-tunnel.sh setup <hostname>}"
  valid_host "$HOST" || { echo "not a valid hostname: $HOST" >&2; exit 2; }
  TOKEN="${CF_TOKEN:-}"
  if [ -z "$TOKEN" ]; then
    read -rsp "Paste the tunnel token (or the whole install command from the dashboard): " TOKEN </dev/tty; echo
  fi
  # The dashboard shows "cloudflared service install eyJ..." — keep just the token
  TOKEN=$(printf '%s' "$TOKEN" | grep -oE 'eyJ[A-Za-z0-9_=+/-]{40,}' | tail -n 1 || true)
  valid_token "$TOKEN" || { echo "That does not look like a Cloudflare tunnel token" >&2; exit 1; }
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  (umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE"); unset TOKEN
  env_set CF_HOSTNAME "$HOST"
  echo "== saved token to $TOKEN_FILE (600), CF_HOSTNAME=$HOST"
  command -v cloudflared >/dev/null ||
    echo "!! cloudflared not found on PATH or in ~/.local/bin — the keep-alive needs it"
  echo "   (don't run 'cloudflared service install': the keep-alive runs cloudflared, fail-closed)"
  if access_check "$HOST"; then
    echo "== Cloudflare Access is active — restart the keep-alive to start the tunnel:"
    echo "   bash $DIR/service.sh restart    (from a normal terminal, not inside pi-web)"
  else
    echo "!! $HOST is not behind Cloudflare Access (yet). The keep-alive refuses to start the"
    echo "   tunnel until it is. New tunnel wizard waiting for a connector? -> cf-tunnel.sh connect"
  fi
  ;;
connect)
  # The dashboard wizard won't let you add the route until a connector is online, but the
  # keep-alive won't start one until the hostname is behind Access. A tunnel without routes
  # exposes nothing, so connect temporarily while the hostname doesn't resolve anywhere yet
  # (or is already behind Access); the keep-alive takes over afterwards.
  MIN="${2:-10}"
  case "$MIN" in ''|*[!0-9]*) echo "minutes must be a number" >&2; exit 2 ;; esac
  HOST=$(env_get CF_HOSTNAME); [ -n "$HOST" ] || { echo "run setup first" >&2; exit 1; }
  [ -s "$TOKEN_FILE" ] || { echo "no token — run setup first" >&2; exit 1; }
  r=$(probe "$HOST")
  if is_access_redirect "$r"; then echo "   $HOST is behind Access"
  elif [ "${r%% *}" = 000 ]; then echo "   $HOST does not answer yet (no route/DNS) — safe to connect"
  else echo "$HOST answers ${r%%\?*} but is NOT behind Access — refusing" >&2; exit 1; fi
  pgrep -u "$(id -u)" -x cloudflared >/dev/null && { echo "cloudflared already running"; exit 0; }
  echo "== connecting for $MIN minutes (log: $CF_LOG)"
  TUNNEL_TOKEN="$(cat "$TOKEN_FILE")" cloudflared --no-autoupdate tunnel run >>"$CF_LOG" 2>&1 &
  pid=$!; trap 'kill $pid 2>/dev/null || true' EXIT INT TERM
  ( sleep $((MIN * 60)); kill $pid 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait $pid || true
  kill $w 2>/dev/null || true
  echo "== temporary connection ended"
  ;;
others)
  LIST="${2:?usage: cf-tunnel.sh others <host1,host2> | none}"
  [ -n "$(env_get CF_HOSTNAME)" ] || { echo "run setup first" >&2; exit 1; }
  if [ "$LIST" = none ]; then env_set CF_OTHER_HOSTNAMES ""; echo "== cleared CF_OTHER_HOSTNAMES"; exit 0; fi
  for h in ${LIST//,/ }; do valid_host "$h" || { echo "not a valid hostname: $h" >&2; exit 2; }; done
  env_set CF_OTHER_HOSTNAMES "$LIST"
  echo "== CF_OTHER_HOSTNAMES=$LIST"
  bad=0
  for h in ${LIST//,/ }; do access_check "$h" || { echo "!! $h is NOT behind Access"; bad=1; }; done
  [ $bad = 0 ] || echo "!! The keep-alive stops the WHOLE tunnel until every hostname is behind Access."
  echo "Next: bash $DIR/service.sh restart"
  ;;
check)
  HOST="${2:-$(env_get CF_HOSTNAME)}"; [ -n "$HOST" ] || { echo "no CF_HOSTNAME in $ENV_FILE" >&2; exit 1; }
  if access_check "$HOST"; then echo "OK: behind Cloudflare Access"; else echo "NOT protected by Cloudflare Access"; exit 1; fi
  ;;
status)
  HOST=$(env_get CF_HOSTNAME); O=$(env_get CF_OTHER_HOSTNAMES)
  echo "hostname:    ${HOST:-<none>}"
  echo "token:       $([ -s "$TOKEN_FILE" ] && echo "present ($(perm "$TOKEN_FILE"))" || echo missing)"
  echo "cloudflared: $(pgrep -u "$(id -u)" -x cloudflared >/dev/null && echo running || echo stopped)"
  for h in $HOST ${O//,/ }; do
    if access_check "$h"; then echo "   $h: protected"; else echo "   $h: NOT protected"; fi
  done
  tail -n 3 "$CF_LOG" 2>/dev/null | sed 's/^/   /' || true
  ;;
disable)
  rm -f "$TOKEN_FILE"        # first, so the keep-alive can't start it again
  pkill -u "$(id -u)" -x cloudflared && echo "stopped cloudflared" || true
  env_set CF_HOSTNAME ""; env_set CF_OTHER_HOSTNAMES ""
  echo "removed token, CF_HOSTNAME and CF_OTHER_HOSTNAMES."
  echo "Run service.sh restart (drops the hostname from pi-web's allow-list), then delete"
  echo "the tunnel route and the Access application in the Cloudflare dashboard."
  ;;
*) sed -n '2,15p' "$0"; exit 2 ;;
esac
