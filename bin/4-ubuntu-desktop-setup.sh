#!/usr/bin/env bash
# TapTether X11 desktop integration; run as the desktop user, not with sudo.
set -euo pipefail

BIN="$HOME/.local/bin/taptetherctl"
SERVICE="$HOME/.config/systemd/user/taptether-agent.service"
APP="$HOME/.local/share/applications/taptether.desktop"
AUTOSTART="$HOME/.config/autostart/taptether-agent.desktop"
STATE="$HOME/.local/state/taptether"
UNIT=taptether-agent.service

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'TapTether: %s\n' "$*"; }
user_bus() {
  local rt="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-$rt}"
  if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  fi
}
manager_value() {
  systemctl --user show-environment 2>/dev/null | sed -n "s/^$1=//p" | head -n 1
}
gui_session_type() {
  local sid typ
  if command -v loginctl >/dev/null 2>&1; then
    sid="$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null || true)"
    if [[ -n "$sid" ]]; then
      typ="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
      if [[ "$typ" == x11 || "$typ" == wayland ]]; then printf '%s' "$typ"; return; fi
    fi
  fi
  typ="$(manager_value XDG_SESSION_TYPE)"
  if [[ "$typ" == x11 || "$typ" == wayland ]]; then printf '%s' "$typ"; return; fi
  if [[ "\${XDG_SESSION_TYPE:-}" == x11 || "\${XDG_SESSION_TYPE:-}" == wayland ]]; then
    printf '%s' "$XDG_SESSION_TYPE"
  fi
}
ensure_x11() {
  command -v xdotool >/dev/null 2>&1 || fail 'xdotool missing; sudo apt install xdotool'
  local typ manager_disp manager_auth disp auth_candidate
  typ="$(gui_session_type)"
  if [[ "$typ" == wayland ]]; then
    fail 'An active Wayland desktop was detected. TapTether 0.2.x needs Ubuntu on Xorg (X11).'
  fi
  manager_disp="$(manager_value DISPLAY)"
  manager_auth="$(manager_value XAUTHORITY)"
  local -a displays=() auths=()
  [[ -n "$manager_disp" ]] && displays+=("$manager_disp")
  if [[ -n "\${DISPLAY:-}" && "$DISPLAY" != localhost:* && "$DISPLAY" != 127.0.0.1:* ]]; then displays+=("$DISPLAY"); fi
  displays+=(':0' ':1' ':2')
  [[ -n "$manager_auth" ]] && auths+=("$manager_auth")
  [[ -n "\${XAUTHORITY:-}" ]] && auths+=("$XAUTHORITY")
  auths+=("/run/user/$(id -u)/gdm/Xauthority" "$HOME/.Xauthority")
  for disp in "\${displays[@]}"; do
    for auth_candidate in "\${auths[@]}"; do
      if [[ -f "$auth_candidate" ]] && env DISPLAY="$disp" XAUTHORITY="$auth_candidate" xdotool getmouselocation >/dev/null 2>&1; then
        export DISPLAY="$disp" XAUTHORITY="$auth_candidate" XDG_SESSION_TYPE=x11
        systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE >/dev/null
        return 0
      fi
    done
    if env -u XAUTHORITY DISPLAY="$disp" xdotool getmouselocation >/dev/null 2>&1; then
      export DISPLAY="$disp" XDG_SESSION_TYPE=x11
      unset XAUTHORITY || true
      systemctl --user import-environment DISPLAY XDG_SESSION_TYPE >/dev/null
      return 0
    fi
  done
  fail 'No accessible X11 desktop found. Log into Ubuntu using "Ubuntu on Xorg", then try again. (SSH by itself has no graphical display.)'
}
pairing() {
  local config="$HOME/.config/taptether" token cert
  token="$config/pairing.token"
  cert="$config/server.crt"
  [[ -r "$token" && -r "$cert" ]] || fail 'Agent has not initialized pairing identity. Start the service first.'
  command -v openssl >/dev/null 2>&1 || fail 'openssl is required to print certificate fingerprint'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
  note 'PRIVATE pairing details. Do not paste your token into chats or tickets.'
  printf 'Host IP: '
  if command -v hostname >/dev/null 2>&1; then hostname -I 2>/dev/null || printf '(check ip addr)\n'; fi
  printf 'Port: 48321\nToken: '
  cat "$token"
  printf 'TLS SHA-256 fingerprint: '
  openssl x509 -in "$cert" -outform DER | sha256sum | awk '{print toupper($1)}'
}
pin() {
  command -v gsettings >/dev/null 2>&1 || { note 'gsettings not found; launcher will still appear in Applications.'; return 1; }
  command -v python3 >/dev/null 2>&1 || { note 'python3 is required to pin to the GNOME dock.'; return 1; }
  user_bus
  python3 - <<'PY'
import ast, subprocess, sys
base=['gsettings','get','org.gnome.shell','favorite-apps']
try:
    raw=subprocess.check_output(base,text=True,stderr=subprocess.PIPE).strip()
    if raw.startswith('@as '): raw=raw[4:]
    apps=ast.literal_eval(raw)
    if not isinstance(apps,list): raise ValueError('GNOME favorites are not a list')
    if 'taptether.desktop' not in apps:
        apps.append('taptether.desktop')
        subprocess.run(['gsettings','set','org.gnome.shell','favorite-apps',str(apps)],check=True,stderr=subprocess.PIPE)
        print('TapTether pinned to GNOME dock.')
    else: print('TapTether is already pinned to GNOME dock.')
except (OSError, subprocess.CalledProcessError, SyntaxError, ValueError) as ex:
    print(f'Could not pin remotely ({ex}). Open Show Applications and right-click TapTether → Add to Favorites.',file=sys.stderr)
    sys.exit(1)
PY
}
install() {
  [[ "$(id -u)" != 0 ]] || fail 'Run as the normal Ubuntu desktop user, not root or sudo.'
  [[ -x /usr/local/bin/taptether-agent ]] || fail 'Install the TapTether .deb first (taptether-agent not found).'
  mkdir -p "\${BIN%/*}" "\${SERVICE%/*}" "\${APP%/*}" "\${AUTOSTART%/*}" "$STATE"
  if [[ "\${BASH_SOURCE[0]}" != "$BIN" ]]; then cp "\${BASH_SOURCE[0]}" "$BIN"; fi
  chmod 700 "$BIN"
  cat > "$SERVICE" <<'SERVICE_EOF'
[Unit]
Description=TapTether local-only remote input (X11 desktop)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/taptether-agent
Restart=on-failure
RestartSec=4
UMask=0077
# stdout contains a private pairing token; avoid putting it into the journal.
StandardOutput=null
StandardError=journal
NoNewPrivileges=true
SERVICE_EOF
  cat > "$APP" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=TapTether Agent
Comment=Start the private TapTether keyboard and trackpad agent
Exec=$BIN start
Icon=input-keyboard
Terminal=false
StartupNotify=false
Categories=Utility;Network;
DESKTOP_EOF
  cat > "$AUTOSTART" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=TapTether (auto-start)
Exec=$BIN session-start
Icon=input-keyboard
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
  systemctl --user daemon-reload || fail 'Cannot reach user systemd. Verify login and SSH user session.'
  note 'Installed desktop launcher, per-user service, and automatic startup at graphical login.'
  if ! pin; then note 'Optional: pin TapTether from Ubuntu Show Applications when logged in.'; fi
  if ! "$BIN" start; then note 'Agent not started yet; it will start automatically when you log into an X11 desktop.'; fi
  note 'SSH: taptetherctl status | start | stop | restart | pairing | logs | pin'
}
start() {
  [[ -f "$SERVICE" ]] || fail "Service missing. Run: bash $(basename "$0") install"
  user_bus
  ensure_x11
  systemctl --user start "$UNIT"
  sleep 1
  systemctl --user is-active --quiet "$UNIT" || fail 'Service failed. Run: taptetherctl logs'
  note "Agent active on X11 DISPLAY=$DISPLAY."
}
status() {
  user_bus
  printf 'Desktop session: %s\n' "$(gui_session_type || true)"
  printf 'X11 display in service manager: %s\n' "$(manager_value DISPLAY)"
  systemctl --user --no-pager status "$UNIT" || true
}
session_start() {
  user_bus
  mkdir -p "$STATE"
  if [[ "\${XDG_SESSION_TYPE:-}" == wayland ]]; then
    printf 'TapTether requires Ubuntu on Xorg, not Wayland.\n' > "$STATE/desktop-status"
    exit 0
  fi
  if ! ensure_x11 > "$STATE/desktop-status" 2>&1; then exit 0; fi
  systemctl --user restart "$UNIT" 2>> "$STATE/desktop-status" || true
}
case "\${1:-}" in
  install) install ;;
  session-start) session_start ;;
  start) start ;;
  stop) user_bus; systemctl --user stop "$UNIT"; note 'Stopped.' ;;
  restart) user_bus; systemctl --user stop "$UNIT"; start ;;
  status) status ;;
  pairing) pairing ;;
  pin) pin ;;
  logs) user_bus; journalctl --user -u "$UNIT" -n 40 --no-pager; [[ -f "$STATE/desktop-status" ]] && cat "$STATE/desktop-status" ;;
  *) printf 'Usage: taptetherctl {install|start|stop|restart|status|pairing|pin|logs}\n' >&2; exit 2 ;;
esac
