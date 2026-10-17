#!/usr/bin/env bash
# The background agent runs as a system service; the screen helper must run
# inside the logged-in owner's GNOME/X11 desktop session.
set -euo pipefail

HELPER=/usr/share/taptether/taptether_screen.py
UNIT=taptether-screen.service
USER_UNIT="$HOME/.config/systemd/user/$UNIT"
AUTOSTART="$HOME/.config/autostart/taptether-screen.desktop"
RUNTIME="/run/user/$(id -u)"
SOCKET="$RUNTIME/taptether-screen.sock"

say() { printf 'TapTether screen: %s\n' "$*"; }
user_bus() {
  if [[ -S "$RUNTIME/bus" ]]; then
    export XDG_RUNTIME_DIR="$RUNTIME"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"
    return 0
  fi
  return 1
}
dependencies() {
  [[ -s "$HELPER" ]] || { say "screen helper absent from package"; return 1; }
  /usr/bin/python3 -c 'import gi; gi.require_version("Gst", "1.0"); gi.require_version("GstVideo", "1.0"); from gi.repository import Gio,GLib,Gst,GstVideo; from PIL import Image' \
    || { say "missing GStreamer/GI/Pillow dependencies"; return 1; }
}
install_helper() {
  [[ "$(id -u)" != 0 ]] || { say "run as the actual desktop owner, not root"; return 1; }
  [[ -s "$HELPER" ]] || { say "screen helper missing; install the current Ubuntu package"; return 1; }
  install -d -m 0755 "$(dirname "$USER_UNIT")" "$(dirname "$AUTOSTART")"
  cat > "$USER_UNIT" <<'UNITFILE'
[Unit]
Description=TapTether desktop Snapshot and Live helper
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/share/taptether/taptether_screen.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
UNITFILE
  chmod 0644 "$USER_UNIT"
  # Keep a fallback for desktop environments which do not manage the
  # graphical-session.target with systemd --user.
  cat > "$AUTOSTART" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=TapTether Screen Helper
Comment=On-demand private desktop screen sharing
Exec=/usr/bin/python3 /usr/share/taptether/taptether_screen.py
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP
  chmod 0644 "$AUTOSTART"
  if user_bus && systemctl --user daemon-reload >/dev/null 2>&1; then
    systemctl --user enable "$UNIT" >/dev/null 2>&1 || true
    # Do not start capture outside a graphical login or request permission
    # on installation: the helper opens a portal only on first phone request.
    if systemctl --user is-active --quiet graphical-session.target; then
      systemctl --user start "$UNIT" >/dev/null 2>&1 || \
        say "desktop helper will start at next graphical login"
    else
      say "no active graphical session detected; helper will start on desktop login"
    fi
  else
    say "user session bus absent; XDG autostart will start at desktop login"
  fi
  if dependencies; then
    say "installed. Reconnect the iPhone to refresh Snapshot/Live capabilities."
  fi
}
status_helper() {
  say "Ubuntu package: $(/usr/local/bin/taptether-agent --version 2>/dev/null || echo unknown)"
  say "screen helper: $([[ -s "$HELPER" ]] && echo installed || echo MISSING)"
  if dependencies; then say "screen dependencies: available"; fi
  if [[ -S "$SOCKET" ]]; then
    say "desktop screen socket: present ($SOCKET)"
  else
    say "desktop screen socket: NOT RUNNING"
  fi
  if user_bus; then
    say "graphical-session.target: $(systemctl --user is-active graphical-session.target 2>/dev/null || echo unavailable)"
    say "screen service: $(systemctl --user is-active "$UNIT" 2>/dev/null || echo unavailable)"
    systemctl --user --no-pager status "$UNIT" 2>&1 | tail -n 12 || true
    say "recent screen-helper journal entries (no frames or tokens):"
    journalctl --user -u "$UNIT" -n 18 --no-pager -o cat 2>/dev/null | tail -n 18 || true
  else
    say "desktop session bus: unavailable (log into Ubuntu locally)"
  fi
  if [[ -r "$HOME/.cache/taptether/screen-helper.log" ]]; then
    say "recent tray-launched screen errors:"
    tail -n 12 "$HOME/.cache/taptether/screen-helper.log" || true
  fi
}
case "${1:-}" in
  install) install_helper ;;
  status) status_helper ;;
  *) say 'Usage: 10-tt-ubuntu-screen-session.sh {install|status}'; exit 2 ;;
esac
