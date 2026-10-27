# lib.sh — shared helpers, sourced by the other scripts in this folder.
# Must stay compatible with macOS's /bin/bash 3.2 (no mapfile, no ${x,,}, no assoc arrays).

CONF_DIR="$HOME/.config/pi-web"
ENV_FILE="$CONF_DIR/env"
PASS_FILE="$CONF_DIR/password"
TOKEN_FILE="$CONF_DIR/cf-token"
LOG="$HOME/.cache/piweb-keepalive.log"
KEEPALIVE="$HOME/bin/piweb-keepalive.sh"
TS_DIR="$HOME/.local/share/tailscale"
WIN_TS="/mnt/c/Program Files/Tailscale/tailscale.exe"
MAC_TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
export TAILSCALE_BE_CLI=1   # macOS app binary: behave as the CLI, never open the GUI

# Same PATH the keep-alive builds (services don't read ~/.bashrc / ~/.zshrc)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# `|| true`: callers use `set -euo pipefail`, and without nvm the glob matches nothing
_nb=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -n 1 || true)
[ -n "$_nb" ] && export PATH="$_nb:$PATH"
unset _nb

os_kind() {   # linux | wsl | macos
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *) echo other ;;
  esac
}

# ---- ~/.config/pi-web/env (sourced by bash, so only plain values are allowed) ----
env_get() { [ -f "$ENV_FILE" ] || return 0; sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1; }
env_set() {   # env_set KEY VALUE   (empty VALUE removes the key)
  local k=$1 v=$2 tmp
  case "$v" in *[!A-Za-z0-9._,:-]*) echo "refusing unsafe value for $k: $v" >&2; return 2 ;; esac
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"; touch "$ENV_FILE"
  tmp=$(mktemp "$CONF_DIR/.env.XXXXXX")
  grep -v "^$k=" "$ENV_FILE" > "$tmp" || true
  [ -n "$v" ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
list_remove() {  # list_remove "a,b,c" b -> "a,c"
  local x out='' IFS=,
  for x in $1; do
    if [ -n "$x" ] && [ "$x" != "$2" ]; then out="${out:+$out,}$x"; fi
  done
  echo "$out"
}
list_add() {  # list_add "a,b" c -> "a,b,c" (no duplicates)
  case ",$1," in *",$2,"*) echo "$1" ;; *) echo "${1:+$1,}$2" ;; esac
}
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# Are we running inside pi-web (its terminal or its agent)? pi-web exports this to children.
inside_piweb() { [ -n "${PI_WEB_ALLOWED_HOSTS+x}" ]; }

# ---- keep-alive processes: match the exact command line, never `pkill -f` ----
keepalive_pids() {   # this user's watchdog: "[/bin/]bash $HOME/bin/piweb-keepalive.sh"
  ps -u "$(id -u)" -o pid=,args= | awk -v k="$KEEPALIVE" '$2 ~ /(^|\/)bash$/ && $3 == k {print $1}'
}

# ---- Cloudflare Access probe (same logic as the keep-alive) ----
probe() {     # prints "<http_code> <redirect_url>"; retries via Cloudflare DoH if local DNS fails
  local r
  r=$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "https://$1/" 2>/dev/null) || true
  case "$r" in ""|000*)
    # Home routers cache "no such domain" for up to 30 min after a hostname is created
    r=$(curl -s -o /dev/null --max-time 15 --doh-url https://1.1.1.1/dns-query \
      -w '%{http_code} %{redirect_url}' "https://$1/" 2>/dev/null) || true ;;
  esac
  echo "${r:-000 }"
}
is_access_redirect() { [[ "$1" =~ ^302\ https://[A-Za-z0-9-]+\.cloudflareaccess\.com/ ]]; }

# ---- Tailscale CLI for a given mode ----
ts_cli() {    # ts_cli <system|own|windows> args...
  local m=$1; shift
  case "$m" in
    own) "$HOME/.local/bin/tailscale" --socket="$TS_DIR/tailscaled.sock" "$@" ;;
    windows) "$WIN_TS" "$@" ;;
    system)
      if command -v tailscale >/dev/null 2>&1; then tailscale "$@"
      elif [ -x "$MAC_TS" ]; then "$MAC_TS" "$@"
      else echo "tailscale CLI not found" >&2; return 127; fi ;;
    *) echo "unknown Tailscale mode: $m" >&2; return 2 ;;
  esac
}
ts_dnsname() {  # this device's MagicDNS name, e.g. box.tailXXXX.ts.net (empty if unknown)
  { ts_cli "$1" status --json 2>/dev/null || true; } | tr -d '\r' | awk '
    /"Self"[[:space:]]*:/ {s=1}
    s && !d && /"DNSName"/ { sub(/.*"DNSName"[[:space:]]*:[[:space:]]*"/, ""); sub(/\.?".*/, ""); print; d=1 }'
}
