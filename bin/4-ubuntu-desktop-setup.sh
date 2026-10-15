#!/usr/bin/env bash
# TapTether Ubuntu installer: restricted uinput, background service and system tray.
# Installs a systemd SYSTEM service running as this ordinary desktop user (never root).
set -euo pipefail

UNIT='taptether-agent.service'
SYS_SERVICE="/etc/systemd/system/$UNIT"
OLD_USER_SERVICE="$HOME/.config/systemd/user/$UNIT"
CTL="$HOME/.local/bin/taptetherctl"
UPDATER="$HOME/.local/bin/taptether-agent-update"
POWER_RULE="/etc/polkit-1/rules.d/80-taptether-shutdown.rules"
POWER_DROPIN="/etc/systemd/system/taptether-agent.service.d/40-shutdown.conf"
POWER_DISABLED="$HOME/.config/taptether/remote-shutdown-disabled"
APP="$HOME/.local/share/applications/taptether.desktop"
TRAY="$HOME/.local/share/taptether/taptether_tray.py"
TRAY_AUTOSTART="$HOME/.config/autostart/taptether-tray.desktop"
OLD_AUTOSTART="$HOME/.config/autostart/taptether-agent.desktop"
CONFIG="$HOME/.config/taptether"
AGENT='/usr/local/bin/taptether-agent'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'TapTether: %s\n' "$*"; }
user_bus() {
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}
unpin_legacy_launcher() {
  command -v gsettings >/dev/null 2>&1 || return 0
  user_bus
  python3 - <<'PY' || true
import ast
import subprocess
try:
    raw = subprocess.check_output(
        ['gsettings', 'get', 'org.gnome.shell', 'favorite-apps'],
        text=True, stderr=subprocess.DEVNULL).strip()
    if raw.startswith('@as '):
        raw = raw[4:]
    apps = ast.literal_eval(raw)
    if isinstance(apps, list) and 'taptether.desktop' in apps:
        apps = [app for app in apps if app != 'taptether.desktop']
        subprocess.run(['gsettings', 'set', 'org.gnome.shell',
                        'favorite-apps', str(apps)],
                       check=True, stderr=subprocess.DEVNULL)
except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError):
    pass
PY
}
setup_update_service() {
  local username="$1" homedir="$2" tmp rule
  local source='/usr/share/taptether/9-tt-system-update-ubuntu.sh'
  [[ -s "$source" ]] || {
    note 'Optional privileged update service not bundled yet; the mobile SSH updater remains available.'
    return 0
  }
  sudo install -D -m 0755 "$source"     /usr/local/libexec/taptether-update-ubuntu.sh
  tmp="$(mktemp)"
  cat > "$tmp" <<SYSTEMD
[Unit]
Description=TapTether user-approved verified agent update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="TAPTETHER_OWNER=$username"
Environment="TAPTETHER_HOME=$homedir"
ExecStart=/usr/local/libexec/taptether-update-ubuntu.sh
NoNewPrivileges=true
PrivateTmp=true
TimeoutStartSec=300
UMask=0077
SYSTEMD
  sudo install -m 0644 "$tmp"     /etc/systemd/system/taptether-update.service
  rm -f "$tmp"
  # Narrow permission: one named unit, one named verb, this desktop user.
  # It does not grant passwordless sudo or access to other system services.
  tmp="$(mktemp)"
  cat > "$tmp" <<POLKIT
polkit.addRule(function(action, subject) {
  if (action.id === "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit") === "taptether-update.service" &&
      action.lookup("verb") === "start" &&
      subject.user === "$username") {
    return polkit.Result.YES;
  }
});
POLKIT
  sudo install -D -m 0644 "$tmp"     /etc/polkit-1/rules.d/80-taptether-update.rules
  rm -f "$tmp"
  sudo systemctl daemon-reload
}
setup_permissions() {
  # Only the daemon receives the privileged input group through systemd.
  # The interactive user is NOT added to this group.
  sudo groupadd --system --force taptether
  printf 'uinput\n' | sudo tee /etc/modules-load.d/taptether-uinput.conf >/dev/null
  printf 'KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="taptether", MODE="0660"\n' \
    | sudo tee /etc/udev/rules.d/80-taptether-uinput.rules >/dev/null
  sudo modprobe uinput
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
  [[ -e /dev/uinput ]] || fail '/dev/uinput not available on this Ubuntu kernel.'
  sudo chgrp taptether /dev/uinput
  sudo chmod 0660 /dev/uinput
}
pairing() {
  [[ -r "$CONFIG/pairing.token" && -r "$CONFIG/server.crt" ]] || \
    fail 'No pairing credentials yet. Start the service, then run taptetherctl pairing.'
  note 'PRIVATE credentials below; do not share them or publish installation logs.'
  printf 'LAN IP(s): '
  hostname -I 2>/dev/null || true
  printf 'Port: 48321\nPairing token: '
  cat "$CONFIG/pairing.token"
  printf 'TLS certificate SHA-256 fingerprint: '
  openssl x509 -in "$CONFIG/server.crt" -outform DER | sha256sum | awk '{print toupper($1)}'
}
pairing_qr() {
  command -v qrencode >/dev/null 2>&1 || fail 'Install QR renderer: sudo apt install qrencode'
  [[ -r "$CONFIG/pairing.token" && -r "$CONFIG/server.crt" ]] || fail 'Agent not initialized'
  local host token fingerprint uri
  host="$(hostname -I | awk '{print $1}')"
  token="$(tr -d '\n' < "$CONFIG/pairing.token")"
  fingerprint="$(openssl x509 -in "$CONFIG/server.crt" -outform DER | sha256sum | awk '{print toupper($1)}')"
  uri="$(printf '%s\n%s\n%s\n' "$host" "$token" "$fingerprint" |
    python3 -c 'import sys,urllib.parse; h,t,f=sys.stdin.read().splitlines(); print("taptether://pair?"+urllib.parse.urlencode({"v":"1","host":h,"token":t,"fingerprint":f}))')"
  note 'PRIVATE pairing QR — show only on a trusted terminal.'
  printf '%s' "$uri" | qrencode -t ANSIUTF8 -o -
}
devices() { "$AGENT" --list-devices; }
revoke_device() {
  [[ "$2" =~ ^[0-9a-f]{32}$ ]] || fail 'Supply a device ID from taptetherctl devices'
  "$AGENT" --revoke-device "$2"
}
ensure_running() {
  local attempt
  for attempt in $(seq 1 20); do
    if systemctl is-active --quiet "$UNIT" &&
       [[ -s "$CONFIG/pairing.token" && -s "$CONFIG/server.crt" ]]; then
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --full status "$UNIT" >&2 || true
  fail 'Service did not initialize in 20 seconds. Check: sudo journalctl -u taptether-agent -n 60'
}
install() {
  [[ "$(id -u)" != 0 ]] || fail 'Run installer as the Ubuntu desktop user, not root.'
  [[ -x "$AGENT" ]] || fail 'Install the TapTether .deb first.'
  command -v sudo >/dev/null 2>&1 || fail 'sudo required for a secure systemd service.'
  command -v systemctl >/dev/null 2>&1 || fail 'systemd required.'
  command -v openssl >/dev/null 2>&1 || fail 'openssl required for pairing fingerprint.'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum required for pairing fingerprint.'
  local username homedir tmp
  username="$(id -un)"
  homedir="$HOME"
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail 'Unsafe username for unit file.'
  [[ "$homedir" == /* && "$homedir" != *$'\n'* ]] || fail 'Invalid home directory.'
  note 'Configuring /dev/uinput permissions for the service only.'
  setup_permissions
  setup_update_service "$username" "$homedir"
  mkdir -p "${CTL%/*}" "${APP%/*}" "$CONFIG" "${TRAY%/*}" "${TRAY_AUTOSTART%/*}"
  chmod 700 "$CONFIG"
  if [[ "$(realpath "${BASH_SOURCE[0]}")" != "$(realpath -m "$CTL")" ]]; then
    cp "${BASH_SOURCE[0]}" "$CTL"
  fi
  chmod 700 "$CTL"
  if [[ -f "$(dirname "$0")/7-tt-update-ubuntu.sh" ]]; then
    command install -m 0700 "$(dirname "$0")/7-tt-update-ubuntu.sh" "$UPDATER"
  fi
  if [[ -s "$(dirname "$0")/TapTether-icon.png" ]]; then
    command install -d -m 0755 "$HOME/.local/share/icons/hicolor/512x512/apps"
    command install -m 0644 "$(dirname "$0")/TapTether-icon.png" "$HOME/.local/share/icons/hicolor/512x512/apps/taptether.png"
  else
    note 'TapTether icon was not supplied; reinstall using the current SSH installer for branding.'
  fi
  if [[ -s "$(dirname "$0")/taptether_tray.py" ]]; then
    command install -m 0755 "$(dirname "$0")/taptether_tray.py" "$TRAY"
    # These packages run in the desktop session, never in the privileged agent.
    if command -v apt-get >/dev/null 2>&1; then
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
        >/dev/null 2>&1 || note 'Tray dependencies unavailable; install python3-gi, GTK3 and Ayatana AppIndicator manually.'
    fi
  else
    note 'Desktop tray script not staged; installer will still run the background agent.'
  fi
  local launcher_exec launcher_comment
  if [[ -s "$TRAY" ]]; then
    launcher_exec="/usr/bin/python3 $TRAY --splash"
    launcher_comment='Open TapTether desktop splash and tray'
  else
    launcher_exec="$CTL start"
    launcher_comment='Start TapTether background agent'
  fi
  cat > "$APP" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=TapTether Agent
Comment=$launcher_comment
Exec=$launcher_exec
Icon=taptether
Terminal=false
StartupNotify=false
Categories=Network;Utility;
DESKTOP
  if [[ -s "$TRAY" ]]; then
    cat > "$TRAY_AUTOSTART" <<DESKTOP
[Desktop Entry]
Type=Application
Name=TapTether Tray
Comment=Show TapTether agent controls in the system tray at desktop login
Exec=/usr/bin/python3 $TRAY
Icon=taptether
Terminal=false
X-GNOME-Autostart-enabled=true
StartupNotify=false
NoDisplay=true
DESKTOP
    chmod 0644 "$TRAY_AUTOSTART"
  fi
  # Migrate from legacy desktop-login systemd user service. Avoid port 48321 collisions.
  user_bus
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$OLD_AUTOSTART" "$OLD_USER_SERVICE"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  pkill -u "$(id -u)" -x taptether-agent >/dev/null 2>&1 || true
  tmp="$(mktemp)"
  cat > "$tmp" <<SYSTEMD
[Unit]
Description=TapTether private LAN keyboard, trackpad and volume agent
After=systemd-modules-load.service network.target

[Service]
Type=simple
User=$username
SupplementaryGroups=taptether
Environment="HOME=$homedir"
ExecStart=$AGENT
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=full
PrivateTmp=true
# The agent prints its secret token on stdout: never put stdout in the system journal.
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD
  sudo install -m 0644 "$tmp" "$SYS_SERVICE"
  rm -f "$tmp"
  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT"
  sudo systemctl restart "$UNIT"
  ensure_running
  # Computer owner requested default ON for all agents. Existing explicit
  # disable marker must survive repair and updates.
  if [[ ! -f "$POWER_DISABLED" ]]; then
    enable_shutdown
  fi
  # Earlier builds pinned the launcher to GNOME Favorites. Remove only
  # that legacy auto-pin; the tray remains available without a taskbar icon.
  unpin_legacy_launcher
  note 'Agent running in the background and enabled at boot (even before login).'
  note 'The TapTether tray icon starts at the next graphical login.'
  note 'You can retrieve credentials later with: ~/.local/bin/taptetherctl pairing'
  printf '\n====== TapTether pairing details ======\n'
  pairing
  printf '=======================================\n'
  note 'SSH controls: ~/.local/bin/taptetherctl {start|stop|restart|status|pairing|check-update|update|enable-shutdown|disable-shutdown}'
  note 'The GNOME panel may require AppIndicator support; the systemd service does not depend on the tray.'
  note 'Security: uinput grants control even at the lock/login screen. Restrict TCP 48321 to trusted LAN devices.'
}
start() {
  sudo systemctl start "$UNIT"
  ensure_running
  note 'Agent running in background.'
}
stop() { sudo systemctl stop "$UNIT"; note 'Agent stopped.'; }
restart() { sudo systemctl restart "$UNIT"; ensure_running; note 'Agent restarted.'; }
status() {
  systemctl --no-pager --full status "$UNIT" || true
  printf '\nAuto-start at reboot: '
  systemctl is-enabled "$UNIT" || true
}
permissions() {
  ls -l /dev/uinput 2>&1 || true
  printf 'Expected input group: taptether (assigned to systemd service, not your SSH shell)\n'
  if systemctl is-active --quiet "$UNIT"; then
    note 'TapTether system service is active.'
  else
    note 'TapTether service is not running.'
  fi
}
enable_shutdown() {
  # Polkit grants only system shutdown, not generic sudo or root privileges.
  local username temp
  username="$(id -un)"
  [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fail 'Invalid username'
  sudo install -d -m 0755 "$(dirname "$POWER_RULE")" "$(dirname "$POWER_DROPIN")"
  temp="$(mktemp)"
  cat >"$temp" <<EOF
polkit.addRule(function(action, subject) {
  if ((action.id === "org.freedesktop.login1.power-off" ||
       action.id === "org.freedesktop.login1.power-off-multiple-sessions") &&
      subject.user === "$username" && subject.isInGroup("taptether")) {
    return polkit.Result.YES;
  }
});
EOF
  sudo install -m 0644 "$temp" "$POWER_RULE"
  printf '[Service]\nEnvironment=TAPTETHER_ENABLE_SHUTDOWN=1\n' > "$temp"
  sudo install -m 0644 "$temp" "$POWER_DROPIN"
  rm -f "$temp"
  sudo systemctl daemon-reload
  mkdir -p "$CONFIG"
  rm -f "$POWER_DISABLED"
  sudo systemctl restart "$UNIT"
  note 'Remote shutdown enabled for paired computers; phone confirmation remains mandatory.'
}
disable_shutdown() {
  mkdir -p "$CONFIG"
  touch "$POWER_DISABLED"
  chmod 600 "$POWER_DISABLED"
  sudo rm -f "$POWER_RULE" "$POWER_DROPIN"
  sudo systemctl daemon-reload
  sudo systemctl restart "$UNIT"
  note 'Remote shutdown disabled.'
}
check_update() {
  [[ -f "$UPDATER" ]] || fail 'Updater missing. Re-run current Ubuntu installer from your Mac.'
  bash "$UPDATER" check
}
update_agent() {
  [[ -f "$UPDATER" ]] || fail 'Updater missing. Re-run current Ubuntu installer from your Mac.'
  bash "$UPDATER" update
}
case "${1:-}" in
  install) install ;;
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  pairing) pairing ;;
  pairing-qr) pairing_qr ;;
  devices) devices ;;
  revoke-device) revoke_device "$@" ;;
  logs) journalctl --no-pager -u "$UNIT" -n 60 ;;
  permissions) permissions ;;
  pin) pin ;;
  check-update) check_update ;;
  update) update_agent ;;
  enable-shutdown) enable_shutdown ;;
  disable-shutdown) disable_shutdown ;;
  session-start) : ;;  # Compatibility with old GNOME autostart references.
  *) printf 'Usage: taptetherctl {install|start|stop|restart|status|pairing|pairing-qr|devices|revoke-device ID|logs|permissions|pin|check-update|update|enable-shutdown|disable-shutdown}\n' >&2; exit 2 ;;
esac
