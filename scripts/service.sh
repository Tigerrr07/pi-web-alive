#!/bin/bash
# service.sh — autostart for the keep-alive, and turning pi-web off / on. Run as the pi-web user.
#
#   service.sh install     Linux: systemd --user unit + linger · macOS: LaunchAgent
#                          WSL: prints the (elevated) PowerShell command for Task Scheduler
#   service.sh stop        turn pi-web off; it stays off (also after reboot) until `start`
#   service.sh start       turn pi-web on again (and back on at boot/login)
#   service.sh restart     apply env / password / script changes (kills the tmux session!)
#   service.sh status
#   service.sh uninstall   remove the autostart (config in ~/.config/pi-web is kept)
#
# stop/restart/uninstall (and install on Linux/macOS) refuse to run inside pi-web: they
# would kill the session running them. Use a normal terminal, or pass --force.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"

CMD="${1:-}"; FORCE="${2:-}"
OS=$(os_kind)
UNIT=piweb-keepalive.service
UNIT_FILE="$HOME/.config/systemd/user/$UNIT"
LABEL=com.user.piweb-keepalive
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"
TASK="${PIWEB_TASK:-WSL pi-web keepalive ($(id -un))}"   # PIWEB_TASK: override for tests

case "$OS" in macos) MGR=launchd ;; wsl) MGR=task ;; linux) MGR=systemd ;; *) MGR=none ;; esac

need_keepalive() { [ -x "$KEEPALIVE" ] || { echo "run setup.sh first ($KEEPALIVE missing)" >&2; exit 1; }; }
guard() {
  if inside_piweb && [ "$FORCE" != --force ]; then
    echo "Refusing: this shell runs inside pi-web, and '$CMD' kills pi-web's tmux session" >&2
    echo "(and with it this agent/terminal). Run it from a normal terminal, or add --force." >&2
    exit 1
  fi
}
stop_procs() {
  local pid
  for pid in $(keepalive_pids); do kill "$pid" 2>/dev/null && echo "stopped keep-alive $pid"; done
  tmux kill-session -t piweb 2>/dev/null && echo "removed tmux session piweb" || true
  # cloudflared keeps the old token in memory; the next keep-alive re-checks Access first
  pkill -u "$(id -u)" -x cloudflared 2>/dev/null && echo "stopped cloudflared" || true
}
ps_task() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }
task_state() { ps_task "(Get-ScheduledTask -TaskName '$TASK' -ErrorAction SilentlyContinue).State" || true; }
# Enabled flag, not State: a disabled task whose instance is still running reports State=Running
task_enabled() { ps_task "(Get-ScheduledTask -TaskName '$TASK' -ErrorAction SilentlyContinue).Settings.Enabled" || true; }
start_manual() {
  nohup "$KEEPALIVE" >/dev/null 2>&1 </dev/null &
  echo "started keep-alive manually (pid $!) — not persistent across reboots"
}
installed() {
  case "$MGR" in
    systemd) [ -f "$UNIT_FILE" ] ;;
    launchd) [ -f "$PLIST" ] ;;
    task)    [ -n "$(task_state)" ] ;;
    *)       return 1 ;;
  esac
}
is_off() {    # turned off with `service.sh stop`?
  case "$MGR" in
    systemd) [ -f "$UNIT_FILE" ] && [ "$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)" != enabled ] ;;
    launchd) launchctl print-disabled "$GUI" 2>/dev/null | grep -Eq "\"$LABEL\" => (true|disabled)" ;;
    task)    [ "$(task_enabled)" = False ] ;;
    *)       return 1 ;;
  esac
}
wait_keepalive() {   # $1 = what to report
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(keepalive_pids)" ] && { echo "$1"; return 0; }; sleep 1; done
  echo "!! no keep-alive process yet — check status.sh in a minute"
}

case "$CMD" in
install)
  need_keepalive
  [ "$MGR" = task ] || guard     # installing replaces (kills) a running tmux session "piweb"
  case "$MGR" in
  systemd)
    systemctl --user show-environment >/dev/null 2>&1 ||
      { echo "no systemd user session here (try: ssh in as this user, or loginctl enable-linger)" >&2; exit 1; }
    TMUX_BIN=$(command -v tmux)
    mkdir -p "$(dirname "$UNIT_FILE")"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=pi-web in tmux (keep-alive, Tailscale serve, Cloudflare tunnel)

[Service]
Type=simple
ExecStart=/bin/bash %h/bin/piweb-keepalive.sh
ExecStopPost=-$TMUX_BIN kill-session -t piweb
# Only signal the watchdog: the tmux server may also hold the user's own sessions
KillMode=process
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    stop_procs >/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT"
    echo "== systemd user service enabled: $UNIT_FILE"
    if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
      loginctl enable-linger "$(id -un)" 2>/dev/null ||
        echo "!! run once: sudo loginctl enable-linger $(id -un)   (start at boot, survive logout)"
    fi
    systemctl --user --no-pager status "$UNIT" | head -5 || true
    ;;
  launchd)
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$KEEPALIVE</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/.cache/piweb-launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/.cache/piweb-launchd.log</string>
</dict>
</plist>
EOF
    launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
    stop_procs >/dev/null || true
    launchctl enable "$GUI/$LABEL"      # clears an earlier `service.sh stop`
    launchctl bootstrap "$GUI" "$PLIST"
    echo "== LaunchAgent loaded: $PLIST (starts when $(id -un) logs in)"
    echo "   keep the Mac awake: sudo pmset -c sleep 0   (or System Settings -> Energy)"
    ;;
  task)
    WP=$(wslpath -w "$DIR/register-task.ps1")
    echo "Windows Task Scheduler starts WSL + the keep-alive at boot (no login needed)"
    echo "and re-checks every 5 minutes. Run this in an ELEVATED PowerShell (Run as administrator):"
    echo
    echo "  powershell -ExecutionPolicy Bypass -File \"$WP\" -LinuxUser $(id -un) -Distro ${WSL_DISTRO_NAME:-Ubuntu}"
    echo
    echo "(Non-elevated also works but then it only runs while you are logged in to Windows.)"
    ;;
  *) echo "unsupported OS — run $KEEPALIVE yourself" >&2; exit 1 ;;
  esac
  ;;
stop)
  guard; need_keepalive
  case "$MGR" in
  systemd) [ -f "$UNIT_FILE" ] && systemctl --user disable --now "$UNIT" 2>/dev/null || true ;;
  launchd) if [ -f "$PLIST" ]; then
             launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
             launchctl disable "$GUI/$LABEL"
           fi ;;
  task)    # pause the task first, otherwise its 5-minute check starts pi-web again
           if installed && [ "$(ps_task "Disable-ScheduledTask -TaskName '$TASK' | Out-Null; (Get-ScheduledTask -TaskName '$TASK').Settings.Enabled" || true)" != False ]; then
             echo "!! could not pause the task. Run in an elevated PowerShell:" >&2
             echo "   Disable-ScheduledTask -TaskName '$TASK'" >&2
             echo "   (until then the task starts pi-web again within 5 minutes)" >&2
           fi ;;
  esac
  stop_procs
  echo "pi-web is off and stays off (also after a reboot) until: service.sh start"
  ;;
start)
  need_keepalive
  if ! installed; then
    echo "no autostart installed (service.sh install)."
    if [ -n "$(keepalive_pids)" ]; then echo "keep-alive already running"; else start_manual; fi
    exit 0
  fi
  if ! is_off && [ -n "$(keepalive_pids)" ]; then echo "pi-web is already on"; exit 0; fi
  case "$MGR" in
  systemd) systemctl --user enable --now "$UNIT" ;;
  launchd) launchctl enable "$GUI/$LABEL"
           launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null || launchctl kickstart "$GUI/$LABEL" ;;
  task)    st=$(ps_task "Enable-ScheduledTask -TaskName '$TASK' | Out-Null; Start-ScheduledTask -TaskName '$TASK'; (Get-ScheduledTask -TaskName '$TASK').State" || true)
           if [ "$st" != Running ]; then
             echo "!! could not start the task (state: ${st:-?}). Run in an elevated PowerShell:" >&2
             echo "   Enable-ScheduledTask -TaskName '$TASK'; Start-ScheduledTask -TaskName '$TASK'" >&2
             exit 1
           fi ;;
  esac
  wait_keepalive "pi-web is on (and starts again at boot/login)"
  ;;
restart)
  guard; need_keepalive
  if is_off; then echo "pi-web is turned off — turn it on with: service.sh start" >&2; exit 1; fi
  case "$MGR" in
  systemd)
    if [ -f "$UNIT_FILE" ]; then
      systemctl --user stop "$UNIT"; stop_procs; systemctl --user start "$UNIT"; echo "restarted $UNIT"
    else stop_procs; start_manual; fi ;;
  launchd)
    if [ -f "$PLIST" ]; then
      launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; stop_procs
      launchctl bootstrap "$GUI" "$PLIST"; echo "restarted $LABEL"
    else stop_procs; start_manual; fi ;;
  task)
    stop_procs
    sleep 3   # let Task Scheduler notice the old instance ended (IgnoreNew would skip the start)
    st=$(ps_task "Start-ScheduledTask -TaskName '$TASK'; (Get-ScheduledTask -TaskName '$TASK').State" || true)
    if [ "$st" = Running ]; then wait_keepalive "restarted via task '$TASK'"
    else echo "!! task '$TASK' not found or not startable (register it: service.sh install)"; start_manual; fi ;;
  *) stop_procs; start_manual ;;
  esac
  ;;
status)
  echo "os/manager:  $OS / $MGR"
  if installed; then
    if is_off; then echo "switch:      OFF (service.sh stop) — turn on with: service.sh start"
    else echo "switch:      on (starts at boot/login)"; fi
  else echo "switch:      no autostart installed (service.sh install)"; fi
  case "$MGR" in
  systemd) en=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)   # prints "disabled" AND exits 1
           echo "service:     ${en:-not-installed}, $(systemctl --user is-active "$UNIT" 2>/dev/null || true)"
           echo "linger:      $(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo '?')" ;;
  launchd) echo "agent:       $(launchctl print "$GUI/$LABEL" 2>/dev/null | awk -F'= ' '/^\tstate/ {print $2; exit}' || true)" ;;
  task)    echo "task:        $(ps_task "\$t=Get-ScheduledTask -TaskName '$TASK' -ErrorAction SilentlyContinue; if(\$t){\$t.State.ToString()+', logon '+\$t.Principal.LogonType}else{'not registered'}")" ;;
  esac
  echo "keep-alive:  $(keepalive_pids | wc -l | tr -d ' ') running (should be 1 when on)"
  ;;
uninstall)
  guard
  case "$MGR" in
  systemd) systemctl --user disable --now "$UNIT" 2>/dev/null || true; rm -f "$UNIT_FILE"; systemctl --user daemon-reload || true
           echo "removed systemd user service $UNIT (linger left as is: loginctl disable-linger $(id -un))" ;;
  launchd) launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; rm -f "$PLIST"
           echo "removed LaunchAgent $LABEL" ;;
  task)    echo "Remove the Windows task in an elevated PowerShell:"
           echo "  powershell -ExecutionPolicy Bypass -File \"$(wslpath -w "$DIR/register-task.ps1")\" -LinuxUser $(id -un) -Remove" ;;
  esac
  stop_procs
  echo "pi-web stopped; config kept in $CONF_DIR"
  ;;
*) sed -n '2,14p' "$0"; exit 2 ;;
esac

exit 0
