#!/usr/bin/env bash
# Explicit, owner-initiated uninstall. Never called by install/update.
set -euo pipefail
fail() { printf 'TapTether uninstall: %s\n' "$*" >&2; exit 1; }
note() { printf 'TapTether uninstall: %s\n' "$*"; }

if [[ "${1:-}" == "--system" ]]; then
  [[ "$(id -u)" == 0 ]] || fail 'System removal requires administrator authorization.'
  [[ $# -eq 1 ]] || fail 'Unexpected system removal arguments.'
  if [[ -f /etc/systemd/system/taptether-agent.service ]]; then
    systemctl disable --now taptether-agent.service \
      || fail 'Could not stop agent; no files removed.'
  fi
  if [[ -f /etc/systemd/system/taptether-update.service ]]; then
    systemctl stop taptether-update.service || true
  fi
  # Exact installer-owned paths; do not touch unrelated services or groups.
  rm -f -- \
    /etc/systemd/system/taptether-agent.service \
    /etc/systemd/system/taptether-update.service \
    /etc/systemd/system/taptether-agent.service.d/40-shutdown.conf \
    /etc/polkit-1/rules.d/80-taptether-shutdown.rules \
    /etc/polkit-1/rules.d/80-taptether-update.rules \
    /etc/modules-load.d/taptether-uinput.conf \
    /etc/udev/rules.d/80-taptether-uinput.rules \
    /usr/local/libexec/taptether-update-ubuntu.sh
  rmdir /etc/systemd/system/taptether-agent.service.d 2>/dev/null || true
  systemctl daemon-reload
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
  fi
  if dpkg-query -W -f='${Status}' taptether-agent 2>/dev/null \
      | grep -q 'install ok installed'; then
    # Exit via dpkg: do not read more of a package-owned script as it is removed.
    exec dpkg --remove taptether-agent
  fi
  rm -f -- /usr/local/bin/taptether-agent
  note 'Removed TapTether system services and legacy binary.'
  exit 0
fi

mode="${1:-}"
[[ $# -eq 1 && ( "$mode" == "--keep-pairing" || "$mode" == "--erase-pairing" ) ]] \
  || fail 'Specify exactly --keep-pairing or --erase-pairing.'
[[ "$(id -u)" != 0 ]] || fail 'Run as your Ubuntu desktop user, not root.'
command -v pkexec >/dev/null 2>&1 \
  || fail 'Graphical administrator authorization (pkexec) is not installed.'
# No owner files are removed when administrator approval fails.
pkexec /bin/bash /usr/share/taptether/4-ubuntu-uninstall.sh --system \
  || fail 'Authorization cancelled or package removal failed.'
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now taptether-screen.service >/dev/null 2>&1 || true
  systemctl --user disable --now taptether-agent.service >/dev/null 2>&1 || true
fi
rm -f -- \
  "$HOME/.config/autostart/taptether-tray.desktop" \
  "$HOME/.config/autostart/taptether-screen.desktop" \
  "$HOME/.config/autostart/taptether-agent.desktop" \
  "$HOME/.local/share/applications/taptether.desktop" \
  "$HOME/.local/share/taptether/taptether_tray.py" \
  "$HOME/.local/share/icons/hicolor/512x512/apps/taptether.png" \
  "$HOME/.config/systemd/user/taptether-agent.service" \
  "$HOME/.config/systemd/user/taptether-screen.service" \
  "$HOME/.local/bin/taptether-agent-update"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi
rm -rf -- "$HOME/.cache/taptether"
rmdir "$HOME/.local/share/taptether" 2>/dev/null || true
if [[ "$mode" == "--erase-pairing" ]]; then
  rm -rf -- "$HOME/.config/taptether"
  note 'TapTether pairing and authorization data erased.'
else
  note 'Pairing and authorization data retained for reinstall.'
fi
# Remove the owner command last.
rm -f -- "$HOME/.local/bin/taptether-uninstall" \
         "$HOME/.local/bin/taptetherctl"
note 'TapTether Ubuntu agent and tray uninstalled.'
