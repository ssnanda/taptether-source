#!/usr/bin/env bash
# Install, start and manage TapTether as a background macOS LaunchAgent.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APP="$BIN/taptether-agent"
CTL="$BIN/taptetherctl-mac"
UPDATER="$BIN/taptether-agent-update-mac"
PLIST="$HOME/Library/LaunchAgents/com.taptether.agent.plist"
LOGDIR="$HOME/Library/Logs/TapTether"
CONF="$HOME/Library/Application Support/taptether"
SHUTDOWN_DISABLED="$HOME/Library/Application Support/taptether/remote-shutdown-disabled"
LABEL=com.taptether.agent
TRAY_LABEL=com.taptether.tray
TRAY_PLIST="$HOME/Library/LaunchAgents/$TRAY_LABEL.plist"
TRAY_BUNDLE="$HOME/Applications/TapTether Agent.app"
TARGET="gui/$(id -u)"
notice() { printf 'TapTether: %s\n' "$*"; }
# Never truncate a currently executing shell script during self-update.
# Older taptetherctl-mac/update helper processes can still be reading the
# original inode. Install in the same directory and rename atomically.
atomic_install_helper() {
  local source="$1" destination="$2" mode="$3" staged
  staged="$(mktemp "$BIN/.taptether-helper.XXXXXXXX")" || return 1
  if ! cp "$source" "$staged" || ! chmod "$mode" "$staged" ||
      ! mv -f "$staged" "$destination"; then
    rm -f "$staged"
    return 1
  fi
}
pairing() {
  if [[ ! -r "$CONF/pairing.token" || ! -r "$CONF/server.crt" ]]; then
    notice 'Agent identity not ready. Start agent and retry.' >&2
    return 1
  fi
  # macOS can be connected over Wi-Fi and Ethernet simultaneously.
  # Show all private IPv4 interfaces; the phone can use only a reachable
  # address (normally on the same local subnet as its current Wi-Fi).
  printf 'LAN IP(s) (choose an address reachable from your phone):\n'
  local addresses
  addresses="$(/sbin/ifconfig -a | /usr/bin/awk '
    $1 == "inet" {
      ip=$2
      if (ip ~ /^192[.]168[.]/ || ip ~ /^10[.]/ ||
          ip ~ /^172[.](1[6-9]|2[0-9]|3[01])[.]/) print ip
    }' | /usr/bin/sort -u)"
  if [[ -n "$addresses" ]]; then
    printf '%s\n' "$addresses"
  else
    printf '%s\n' '(no private IPv4 interfaces found)'
  fi
  printf 'Port: 48321\nPairing token (PRIVATE): '
  cat "$CONF/pairing.token"
  printf 'TLS SHA-256 fingerprint: '
  openssl x509 -in "$CONF/server.crt" -outform DER | shasum -a 256 | awk '{print toupper($1)}'
}
install_agent() {
  [[ "$(id -u)" -ne 0 ]] || { notice 'Run as normal macOS user, never with sudo' >&2; exit 1; }
  # Enabled by default for macOS as requested, including upgrades.
  # Persist an explicit OFF toggle across reinstall and agent updates.
  local shutdown_enabled=1
  [[ -f "$SHUTDOWN_DISABLED" ]] && shutdown_enabled=0
  mkdir -p "$BIN" "$(dirname "$PLIST")" "$LOGDIR"
  chmod 700 "$LOGDIR"
  if [[ "$SELF/taptether-agent" != "$APP" ]]; then
    [[ -x "$SELF/taptether-agent" ]] || { notice 'Run setup from extracted agent archive' >&2; exit 1; }
    cp "$SELF/taptether-agent" "$APP"
  fi
  if [[ "$0" != "$CTL" ]]; then
    atomic_install_helper "$0" "$CTL" 755
  fi
  if [[ -f "$SELF/taptether-agent-update-mac" && "$SELF/taptether-agent-update-mac" != "$UPDATER" ]]; then
    atomic_install_helper "$SELF/taptether-agent-update-mac" "$UPDATER" 700
  fi
  chmod 755 "$APP" "$CTL"
  # Keep the release binary's existing signature intact. Re-signing every
  # install/repair changes its code identity and can invalidate macOS TCC
  # Accessibility approval even when the agent path stays the same.
  # Only sign genuinely unsigned legacy binaries.
  if command -v codesign >/dev/null 2>&1 &&
      ! codesign --verify "$APP" >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 ||
      notice 'Agent binary signing requires manual macOS approval.'
  fi
  # Supports legacy command-line archives and standalone .app bundles.
  local tray_source="$SELF/TapTetherTray"
  if [[ ! -x "$tray_source" && -x "$SELF/../MacOS/TapTetherTray" ]]; then
    tray_source="$SELF/../MacOS/TapTetherTray"
  fi
  if [[ -s "$SELF/TapTether.icns" && -x "$tray_source" ]]; then
    local bundle="$TRAY_BUNDLE"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    local icon_source icon_target binary_source binary_target
    icon_source="$(cd "$SELF" && pwd -P)/TapTether.icns"
    icon_target="$(cd "$bundle/Contents/Resources" && pwd -P)/TapTether.icns"
    binary_source="$(cd "$(dirname "$tray_source")" && pwd -P)/$(basename "$tray_source")"
    binary_target="$(cd "$bundle/Contents/MacOS" && pwd -P)/TapTetherTray"
    [[ "$icon_source" == "$icon_target" ]] || cp "$SELF/TapTether.icns" "$icon_target"
    [[ "$binary_source" == "$binary_target" ]] || cp "$tray_source" "$binary_target"
    # Include self-install resources for future repairs and direct Finder launch.
    for resource in taptether-agent taptetherctl-mac taptether-agent-update-mac; do
      local src="$SELF/$resource" dest="$bundle/Contents/Resources/$resource"
      [[ -s "$src" ]] || continue
      [[ "$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")" == \
         "$(cd "$(dirname "$dest")" && pwd -P)/$(basename "$dest")" ]] || cp "$src" "$dest"
    done
    chmod 0755 "$bundle/Contents/MacOS/TapTetherTray"
    rm -f "$bundle/Contents/MacOS/TapTetherLauncher"
    local app_version
    app_version="$("$APP" --version 2>/dev/null || echo 0.0.0+0)"
    printf '%s\n' "$app_version" > "$bundle/Contents/Resources/version.txt"
    cat > "$bundle/Contents/Info.plist" <<MACPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taptether.agent.launcher</string>
<key>CFBundleExecutable</key><string>TapTetherTray</string>
<key>CFBundleIconFile</key><string>TapTether.icns</string>
<key>CFBundleName</key><string>TapTether Agent</string>
<key>CFBundleDisplayName</key><string>TapTether Agent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${app_version%%+*}</string>
<key>CFBundleVersion</key><string>${app_version##*+}</string>
<key>LSUIElement</key><true/>
</dict></plist>
MACPLIST
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --deep --sign - --timestamp=none "$bundle" >/dev/null 2>&1 ||
        notice 'Ad-hoc signing of menu-bar app was not possible; macOS may request approval.'
    fi
    cat > "$TRAY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$TRAY_LABEL</string>
<key>ProgramArguments</key><array><string>$bundle/Contents/MacOS/TapTetherTray</string><string>--quiet</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>$LOGDIR/tray.stderr.log</string>
</dict></plist>
EOF
    notice "Created TapTether native menu-bar app at $bundle"
  else
    notice 'Native menu-bar executable was not bundled; background agent will still work.'
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>$LOGDIR/agent.stderr.log</string>
</dict></plist>
EOF
  if [[ "$shutdown_enabled" -eq 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:TAPTETHER_ENABLE_SHUTDOWN string 1" "$PLIST"
  fi
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$TARGET" "$PLIST"
  launchctl kickstart -k "$TARGET/$LABEL"
  if [[ -s "$TRAY_PLIST" ]]; then
    launchctl bootout "$TARGET/$TRAY_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "$TARGET" "$TRAY_PLIST" ||
      notice 'Tray will start at next graphical login.'
  fi
  sleep 2
  local service_state
  service_state="$(launchctl print "$TARGET/$LABEL" 2>/dev/null || true)"
  if [[ "$service_state" != *'state = running'* ]]; then
    notice 'Agent failed to remain running. Review ~/Library/Logs/TapTether/agent.stderr.log' >&2
    exit 1
  fi
  notice 'Background agent installed, running and enabled at login.'
  notice 'TapTether Agent.app displays the splash on demand; the menu bar tray starts silently at login.'
  notice 'Allow TapTether in macOS System Settings > Privacy & Security > Accessibility to enable mouse/keyboard.'
  # Never print pairing tokens in routine install/update logs. The owner can
  # deliberately reveal them from the menu bar or the pairing subcommand.
  notice 'To pair your phone, use the menu-bar Show pairing details command.'
}
pairing_qr() {
  command -v qrencode >/dev/null 2>&1 || { notice 'Install qrencode: brew install qrencode' >&2; exit 1; }
  [[ -r "$CONF/pairing.token" && -r "$CONF/server.crt" ]] || { notice 'Agent is not initialized' >&2; exit 1; }
  local host token fingerprint uri
  host="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
  token="$(tr -d '\n' < "$CONF/pairing.token")"
  fingerprint="$(openssl x509 -in "$CONF/server.crt" -outform DER | shasum -a 256 | awk '{print toupper($1)}')"
  uri="$(printf '%s\n%s\n%s\n' "$host" "$token" "$fingerprint" |
    python3 -c 'import sys,urllib.parse; h,t,f=sys.stdin.read().splitlines(); print("taptether://pair?"+urllib.parse.urlencode({"v":"1","host":h,"token":t,"fingerprint":f}))')"
  notice 'PRIVATE pairing QR. Display only on a trusted terminal.'
  printf '%s' "$uri" | qrencode -t ANSIUTF8 -o -
}
devices() { "$APP" --list-devices; }
revoke_device() {
  [[ "$2" =~ ^[0-9a-f]{32}$ ]] || { notice 'Invalid device ID' >&2; exit 1; }
  "$APP" --revoke-device "$2"
}
enable_shutdown() {
  [[ -f "$PLIST" ]] || { notice 'Install the macOS agent first.' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:TAPTETHER_ENABLE_SHUTDOWN" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:TAPTETHER_ENABLE_SHUTDOWN string 1" "$PLIST"
  mkdir -p "$CONF"
  rm -f "$SHUTDOWN_DISABLED"
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$TARGET" "$PLIST"
  notice 'Remote shutdown enabled; macOS may still request System Events automation approval.'
}
disable_shutdown() {
  [[ -f "$PLIST" ]] || { notice 'Install the macOS agent first.' >&2; return 1; }
  mkdir -p "$CONF"
  touch "$SHUTDOWN_DISABLED"
  chmod 600 "$SHUTDOWN_DISABLED"
  /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:TAPTETHER_ENABLE_SHUTDOWN" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$TARGET" "$PLIST"
  notice 'Remote shutdown disabled.'
}
# Safe, local diagnostics for the Finder menu app. Intentionally do not
# print raw stderr or launchctl dumps: either may contain private identities.
diagnostics() {
  printf 'TapTether macOS agent diagnostics\n'
  printf 'User UID: %s\n' "$(id -u)"
  if [[ -x "$APP" ]]; then
    printf 'Agent version: %s\n' "$("$APP" --version 2>/dev/null || echo unavailable)"
  else
    printf 'Agent binary: missing or not executable\n'
  fi
  if [[ -f "$PLIST" ]]; then
    printf 'LaunchAgent plist: installed\n'
  else
    printf 'LaunchAgent plist: missing (choose Install / Repair agent)\n'
  fi
  local state
  state="$(launchctl print "$TARGET/$LABEL" 2>/dev/null || true)"
  if [[ -z "$state" ]]; then
    printf 'LaunchAgent: not loaded\n'
  elif [[ "$state" == *'state = running'* ]]; then
    printf 'LaunchAgent: running\n'
  else
    printf 'LaunchAgent: loaded but not running\n'
  fi
  local last_exit pid
  last_exit="$(printf '%s\n' "$state" | awk '/last exit code = / {value=$NF} END {if (value != "") print value}')"
  pid="$(printf '%s\n' "$state" | awk '/pid = / {value=$NF} END {if (value != "") print value}')"
  [[ "$last_exit" =~ ^[0-9]+$ ]] && printf 'Last exit code: %s\n' "$last_exit"
  [[ "$pid" =~ ^[0-9]+$ ]] && printf 'Process PID: %s\n' "$pid"
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:48321 -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'TCP 48321: listening\n'
  else
    printf 'TCP 48321: not listening\n'
  fi
  local error_log="$LOGDIR/agent.stderr.log"
  if [[ -s "$error_log" ]]; then
    printf 'Agent error log: present\n'
    if tail -n 30 "$error_log" | grep -Eiq 'address already in use|bind: address already in use'; then
      printf 'Hint: another application may already use port 48321\n'
    elif tail -n 30 "$error_log" | grep -Eiq 'operation not permitted|permission denied'; then
      printf 'Hint: macOS denied a required file or network permission\n'
    elif tail -n 30 "$error_log" | grep -Eiq 'certificate/key incomplete|existing pairing token invalid'; then
      printf 'Hint: existing agent identity is incomplete; do not delete pairing files\n'
    else
      printf 'Hint: agent exited; open Install / Repair agent or inspect local log\n'
    fi
  else
    printf 'Agent error log: empty or missing\n'
  fi
  printf 'Accessibility: check System Settings > Privacy & Security > Accessibility\n'
  printf 'Privacy: no passwords, pairing tokens, certificates or raw log lines included\n'
}

start_agent() {
  [[ -f "$PLIST" ]] || { notice 'Agent not installed. Choose Install / Repair agent first.' >&2; return 1; }
  if ! launchctl print "$TARGET/$LABEL" >/dev/null 2>&1; then
    launchctl bootstrap "$TARGET" "$PLIST" || {
      notice 'Could not load the LaunchAgent. Choose Agent diagnostics / Repair.' >&2
      return 1
    }
  fi
  launchctl kickstart -k "$TARGET/$LABEL" || {
    notice 'LaunchAgent could not start. Choose Agent diagnostics.' >&2
    return 1
  }
  sleep 1
  local state
  state="$(launchctl print "$TARGET/$LABEL" 2>/dev/null || true)"
  if [[ "$state" != *'state = running'* ]]; then
    notice 'Agent started then exited. Choose Agent diagnostics / Install Repair.' >&2
    return 1
  fi
  notice 'TapTether agent is running. Use Show pairing details in the menu bar.'
}

check_update() {
  [[ -f "$UPDATER" ]] || { notice 'Update helper missing; install the newest macOS agent archive.' >&2; exit 1; }
  bash "$UPDATER" check
}
update_agent() {
  [[ -f "$UPDATER" ]] || { notice 'Update helper missing; install the newest macOS agent archive.' >&2; exit 1; }
  bash "$UPDATER" update
}

# Restricted to the current user's standard TapTether install locations.
# Uninstall deliberately does NOT edit macOS TCC/Accessibility (protected by
# the OS). A user must remove that entry in System Settings themselves.
uninstall_agent() {
  [[ "$(id -u)" -ne 0 ]] || {
    notice 'Run uninstall as your normal macOS user, never with sudo.' >&2
    return 1
  }
  local mode="${1:-}"
  if [[ "$mode" != "--keep-pairing" && "$mode" != "--erase-pairing" ]]; then
    notice 'Specify --keep-pairing or --erase-pairing explicitly.' >&2
    return 2
  fi
  # Do not remove any files until the user-owned service jobs have stopped.
  # The tray initiating this command may exit as its LaunchAgent is unloaded;
  # this helper completes independently of the UI process.
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "$TARGET/$TRAY_LABEL" >/dev/null 2>&1 || true
  rm -f -- "$PLIST" "$TRAY_PLIST" "$APP" "$UPDATER"
  rm -rf -- "$TRAY_BUNDLE" "$LOGDIR"
  if [[ "$mode" == "--erase-pairing" ]]; then
    # This deletes saved phone authorizations, the local pairing token,
    # TLS certificate/key and shutdown preferences. Phones must pair again.
    rm -rf -- "$CONF"
  fi
  # Remove the controller itself last, after all other cleanup is complete.
  rm -f -- "$CTL"
  notice 'TapTether agent, tray, launch agents, and logs uninstalled.'
  if [[ "$mode" == "--erase-pairing" ]]; then
    notice 'Local pairing identities, certificates and preferences erased.'
  else
    notice 'Local pairing identities retained for a future reinstall.'
  fi
  notice 'Remove any old TapTether Accessibility entry manually in System Settings.'
}
case "${1:-}" in
  install) install_agent ;;
  start) start_agent ;;
  stop) launchctl bootout "$TARGET/$LABEL" ;;
  restart) start_agent ;;
  status) launchctl print "$TARGET/$LABEL" ;;
  pairing) pairing ;;
  pairing-qr) pairing_qr ;;
  devices) devices ;;
  revoke-device) revoke_device "$@" ;;
  logs) tail -n 50 "$LOGDIR/agent.stderr.log" ;;
  diagnostics) diagnostics ;;
  check-update) check_update ;;
  update) update_agent ;;
  enable-shutdown) enable_shutdown ;;
  disable-shutdown) disable_shutdown ;;
  uninstall) uninstall_agent "${2:-}" ;;
  *) echo 'Usage: taptetherctl-mac {install|start|stop|restart|status|diagnostics|pairing|pairing-qr|devices|revoke-device ID|logs|check-update|update|enable-shutdown|disable-shutdown|uninstall --keep-pairing|uninstall --erase-pairing}' >&2; exit 2 ;;
esac
