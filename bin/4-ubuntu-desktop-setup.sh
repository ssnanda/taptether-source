#!/usr/bin/env bash
# TapTether GNOME Wayland/X11 desktop setup and SSH control.
# Run as your ordinary Ubuntu desktop user. setup uses sudo only for /dev/uinput access.
set -euo pipefail

CTL="$HOME/.local/bin/taptetherctl"
UNIT='taptether-agent.service'
SERVICE="$HOME/.config/systemd/user/$UNIT"
APP="$HOME/.local/share/applications/taptether.desktop"
AUTOSTART="$HOME/.config/autostart/taptether-agent.desktop"
STATUS_DIR="$HOME/.local/state/taptether"

fail() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "TapTether: $*"; }
user_bus() {
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}
manager_value() { systemctl --user show-environment 2>/dev/null | sed -n "s/^$1=//p" | head -n1; }
active_gui() {
  local display_id typ
  display_id="$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null || true)"
  if [[ -n "$display_id" ]]; then
    typ="$(loginctl show-session "$display_id" -p Type --value 2>/dev/null || true)"
    if [[ "$typ" == 'wayland' || "$typ" == 'x11' ]]; then printf '%s\n' "$typ"; return 0; fi
  fi
  # GNOME's session data can be absent from loginctl in some remote-management cases.
  if [[ -S "$XDG_RUNTIME_DIR/wayland-0" ]]; then echo 'wayland'; return 0; fi
  if [[ -n "$(manager_value DISPLAY)" ]]; then echo 'x11'; return 0; fi
  return 1
}
check_access() {
  if [[ -w /dev/uinput ]]; then return 0; fi
  if [[ ! -e /dev/uinput ]]; then
    fail '/dev/uinput missing. Install setup first, or run sudo modprobe uinput.'
  fi
  fail '/dev/uinput not writable by current session. Log out of Ubuntu completely and log back in (or reboot) to activate the taptether group.'
}
setup_permissions() {
  # Do not grant uinput access to everyone. Its keyboard privileges are powerful.
  note 'Configuring restricted /dev/uinput access (sudo required).'
  sudo groupadd --system --force taptether
  sudo usermod -aG taptether "$(id -un)"
  printf 'uinput\n' | sudo tee /etc/modules-load.d/taptether-uinput.conf >/dev/null
  printf 'KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="taptether", MODE="0660"\n' \
    | sudo tee /etc/udev/rules.d/80-taptether-uinput.rules >/dev/null
  sudo modprobe uinput
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
  sudo chgrp taptether /dev/uinput
  sudo chmod 0660 /dev/uinput
  if ! id -nG | tr ' ' '\n' | grep -qx 'taptether'; then
    note 'Your account was added to the taptether group. Log out and log back in (or reboot) before using remote input.'
  fi
}
pin() {
  if ! command -v gsettings >/dev/null; then note 'GNOME gsettings unavailable; use Show Applications to pin TapTether.'; return 0; fi
  user_bus
  if ! python3 - <<'PY'
import ast, subprocess, sys
try:
    raw = subprocess.check_output(['gsettings','get','org.gnome.shell','favorite-apps'], text=True, stderr=subprocess.DEVNULL).strip()
    if raw.startswith('@as '): raw = raw[4:]
    favorites = ast.literal_eval(raw)
    if not isinstance(favorites, list): raise ValueError('bad GNOME favorites')
    if 'taptether.desktop' not in favorites:
        favorites.append('taptether.desktop')
        subprocess.run(['gsettings','set','org.gnome.shell','favorite-apps',str(favorites)], check=True)
    print('TapTether is pinned to the GNOME dock.')
except Exception as exc:
    print('Dock pinning unavailable over SSH:', exc, file=sys.stderr)
    sys.exit(1)
PY
  then note 'Pin manually from GNOME Show Applications → TapTether → Add to Favorites.'; fi
}
install() {
  [[ "$(id -u)" != 0 ]] || fail 'Do not run this script with sudo.'
  [[ -x /usr/local/bin/taptether-agent ]] || fail 'Install the new TapTether .deb first.'
  command -v sudo >/dev/null || fail 'sudo is required for first-time uinput permissions'
  setup_permissions
  mkdir -p "${CTL%/*}" "${SERVICE%/*}" "${APP%/*}" "${AUTOSTART%/*}" "$STATUS_DIR"
  if [[ "$(realpath "${BASH_SOURCE[0]}")" != "$(realpath -m "$CTL")" ]]; then cp "${BASH_SOURCE[0]}" "$CTL"; fi
  chmod 700 "$CTL"
  cat > "$SERVICE" <<'SERVICE_END'
[Unit]
Description=TapTether local authenticated remote input (Wayland/X11)
After=graphical-session.target
[Service]
Type=simple
ExecStart=/usr/local/bin/taptether-agent
Restart=on-failure
RestartSec=5
UMask=0077
# Agent stdout includes the pairing token: keep it out of the journal.
StandardOutput=null
StandardError=journal
NoNewPrivileges=true
[Install]
WantedBy=default.target
SERVICE_END
  cat > "$APP" <<DESKTOP_END
[Desktop Entry]
Type=Application
Name=TapTether Agent
Comment=Control Ubuntu securely from your phone over the local network
Exec=$CTL start
Icon=input-keyboard
Terminal=false
StartupNotify=false
Categories=Network;Utility;
DESKTOP_END
  cat > "$AUTOSTART" <<DESKTOP_END
[Desktop Entry]
Type=Application
Name=TapTether Desktop Autostart
Comment=Start TapTether when you sign in to GNOME
Exec=$CTL session-start
Icon=input-keyboard
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP_END
  user_bus
  systemctl --user daemon-reload
  # Autostart at GUI login, not system boot; avoids root daemon and greeter access.
  systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
  pin
  if [[ -w /dev/uinput ]]; then
    if active_gui >/dev/null; then start; else note 'Service installed; it starts on next graphical login.'; fi
  else
    note 'Installation complete. Log out/in before starting the agent from SSH.'
  fi
  note 'Commands over SSH: ~/.local/bin/taptetherctl {start|stop|restart|status|pairing|logs|permissions|pin}'
}
start() {
  user_bus
  [[ -f "$SERVICE" ]] || fail 'Run: bash 4-ubuntu-desktop-setup.sh install'
  check_access
  if ! active_gui >/dev/null; then
    fail 'No active graphical desktop for this user. Log in to GNOME first; SSH alone does not create a desktop.'
  fi
  systemctl --user start "$UNIT"
  sleep 1
  systemctl --user is-active --quiet "$UNIT" || fail 'Agent failed; run taptetherctl logs'
  note "Agent active; desktop: $(active_gui)."
}
status() {
  user_bus
  printf 'Desktop: %s\n' "$(active_gui || echo 'not logged in')"
  printf '/dev/uinput: '; if [[ -w /dev/uinput ]]; then echo 'accessible'; else echo 'not accessible'; fi
  systemctl --user --no-pager status "$UNIT" || true
}
permissions() {
  ls -l /dev/uinput 2>&1 || true
  printf 'Current groups: '; id -nG
  if [[ -w /dev/uinput ]]; then note 'Input device accessible.'; else note 'Requires graphical re-login/reboot after group setup.'; fi
}
pairing() {
  local conf="$HOME/.config/taptether"
  [[ -r "$conf/pairing.token" && -r "$conf/server.crt" ]] || fail 'Agent identity not initialized yet; start the agent.'
  note 'Private credentials. Do not publish or paste the pairing token into chat.'
  printf 'LAN IP: '; hostname -I 2>/dev/null || true
  printf 'Port: 48321\nToken: '; cat "$conf/pairing.token"
  printf 'Certificate SHA-256 fingerprint: '
  openssl x509 -in "$conf/server.crt" -outform DER | sha256sum | awk '{print toupper($1)}'
}
session_start() {
  user_bus
  mkdir -p "$STATUS_DIR"
  if ! check_access > "$STATUS_DIR/session-start.log" 2>&1; then exit 0; fi
  systemctl --user restart "$UNIT" 2>> "$STATUS_DIR/session-start.log" || true
}
case "${1:-}" in
  install) install ;;
  start) start ;;
  session-start) session_start ;;
  stop) user_bus; systemctl --user stop "$UNIT"; note 'Stopped.' ;;
  restart) user_bus; systemctl --user stop "$UNIT"; start ;;
  status) status ;;
  permissions) permissions ;;
  pairing) pairing ;;
  logs) user_bus; journalctl --user -u "$UNIT" -n 60 --no-pager; [[ ! -f "$STATUS_DIR/session-start.log" ]] || cat "$STATUS_DIR/session-start.log" ;;
  pin) pin ;;
  *) echo 'Usage: taptetherctl {install|start|stop|restart|status|pairing|logs|permissions|pin}' >&2; exit 2 ;;
esac
