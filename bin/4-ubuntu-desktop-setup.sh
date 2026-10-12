#!/usr/bin/env bash
# TapTether Ubuntu installer: restricted uinput access, boot service, dock launcher, SSH management.
# Installs a systemd SYSTEM service running as this ordinary desktop user (never root).
set -euo pipefail

UNIT='taptether-agent.service'
SYS_SERVICE="/etc/systemd/system/$UNIT"
OLD_USER_SERVICE="$HOME/.config/systemd/user/$UNIT"
CTL="$HOME/.local/bin/taptetherctl"
UPDATER="$HOME/.local/bin/taptether-agent-update"
POWER_RULE="/etc/polkit-1/rules.d/80-taptether-shutdown.rules"
POWER_DROPIN="/etc/systemd/system/taptether-agent.service.d/40-shutdown.conf"
APP="$HOME/.local/share/applications/taptether.desktop"
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
pin() {
  if ! command -v gsettings >/dev/null 2>&1; then
    note 'GNOME dock not available here. The launcher remains in Show Applications.'
    return 0
  fi
  user_bus
  if ! python3 - <<'PY'
import ast
import subprocess
import sys
try:
    value = subprocess.check_output(
        ['gsettings', 'get', 'org.gnome.shell', 'favorite-apps'],
        text=True, stderr=subprocess.DEVNULL).strip()
    if value.startswith('@as '):
        value = value[4:]
    entries = ast.literal_eval(value)
    if not isinstance(entries, list):
        raise ValueError('unexpected favorites setting')
    if 'taptether.desktop' not in entries:
        entries.append('taptether.desktop')
        subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'favorite-apps', str(entries)],
                       check=True, stderr=subprocess.DEVNULL)
    print('TapTether added to the GNOME dock.')
except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as exc:
    print('Dock pinning was not possible over SSH:', exc, file=sys.stderr)
    sys.exit(1)
PY
  then
    note 'Pin it manually: Show Applications → TapTether → Add to Favorites.'
  fi
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
  mkdir -p "${CTL%/*}" "${APP%/*}" "$CONFIG"
  chmod 700 "$CONFIG"
  if [[ "$(realpath "${BASH_SOURCE[0]}")" != "$(realpath -m "$CTL")" ]]; then
    cp "${BASH_SOURCE[0]}" "$CTL"
  fi
  chmod 700 "$CTL"
  if [[ -f "$(dirname "$0")/7-tt-update-ubuntu.sh" ]]; then
    install -m 0700 "$(dirname "$0")/7-tt-update-ubuntu.sh" "$UPDATER"
  fi
  cat > "$APP" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=TapTether Agent
Comment=Start TapTether local keyboard, trackpad and volume agent
Exec=$CTL start
Icon=input-keyboard
Terminal=false
StartupNotify=false
Categories=Network;Utility;
DESKTOP
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
  pin
  note 'Agent running now in the background and enabled at system boot (even before desktop login).'
  note 'You can retrieve credentials later with: ~/.local/bin/taptetherctl pairing'
  printf '\n====== TapTether pairing details ======\n'
  pairing
  printf '=======================================\n'
  note 'SSH controls: ~/.local/bin/taptetherctl {start|stop|restart|status|pairing|check-update|update|enable-shutdown|disable-shutdown}'
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
  sudo systemctl restart "$UNIT"
  note 'Remote shutdown enabled. Any phone with the correct pairing token can shut down this computer.'
}
disable_shutdown() {
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
  logs) journalctl --no-pager -u "$UNIT" -n 60 ;;
  permissions) permissions ;;
  pin) pin ;;
  check-update) check_update ;;
  update) update_agent ;;
  enable-shutdown) enable_shutdown ;;
  disable-shutdown) disable_shutdown ;;
  session-start) : ;;  # Compatibility with old GNOME autostart references.
  *) printf 'Usage: taptetherctl {install|start|stop|restart|status|pairing|logs|permissions|pin|check-update|update|enable-shutdown|disable-shutdown}\n' >&2; exit 2 ;;
esac
