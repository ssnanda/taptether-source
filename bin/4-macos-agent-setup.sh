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
LABEL=com.taptether.agent
TRAY_LABEL=com.taptether.tray
TRAY_PLIST="$HOME/Library/LaunchAgents/$TRAY_LABEL.plist"
TRAY_BUNDLE="$HOME/Applications/TapTether Agent.app"
TARGET="gui/$(id -u)"
notice() { printf 'TapTether: %s\n' "$*"; }
pairing() {
  if [[ ! -r "$CONF/pairing.token" || ! -r "$CONF/server.crt" ]]; then
    notice 'Agent identity not ready. Start agent and retry.' >&2
    return 1
  fi
  printf 'LAN IP: '
  ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '(check network settings)'
  printf 'Port: 48321\nPairing token (PRIVATE): '
  cat "$CONF/pairing.token"
  printf 'TLS SHA-256 fingerprint: '
  openssl x509 -in "$CONF/server.crt" -outform DER | shasum -a 256 | awk '{print toupper($1)}'
}
install_agent() {
  [[ "$(id -u)" -ne 0 ]] || { notice 'Run as normal macOS user, never with sudo' >&2; exit 1; }
  local shutdown_enabled=0
  if [[ -f "$PLIST" ]] && /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:TAPTETHER_ENABLE_SHUTDOWN" "$PLIST" 2>/dev/null | grep -qx 1; then
    shutdown_enabled=1
  fi
  mkdir -p "$BIN" "$(dirname "$PLIST")" "$LOGDIR"
  chmod 700 "$LOGDIR"
  if [[ "$SELF/taptether-agent" != "$APP" ]]; then
    [[ -x "$SELF/taptether-agent" ]] || { notice 'Run setup from extracted agent archive' >&2; exit 1; }
    cp "$SELF/taptether-agent" "$APP"
  fi
  if [[ "$0" != "$CTL" ]]; then cp "$0" "$CTL"; fi
  if [[ -f "$SELF/taptether-agent-update-mac" && "$SELF/taptether-agent-update-mac" != "$UPDATER" ]]; then
    cp "$SELF/taptether-agent-update-mac" "$UPDATER"
    chmod 700 "$UPDATER"
  fi
  chmod 755 "$APP" "$CTL"
  if command -v codesign >/dev/null 2>&1; then
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
  pairing
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
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$TARGET" "$PLIST"
  notice 'Remote shutdown enabled; macOS may still request System Events automation approval.'
}
disable_shutdown() {
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
  last_exit="$(printf '%s\n' "$state" | awk '/last exit code = / {print $NF; exit}')"
  pid="$(printf '%s\n' "$state" | awk '/pid = / {print $NF; exit}')"
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
case "$1" in
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
  *) echo 'Usage: taptetherctl-mac {install|start|stop|restart|status|diagnostics|pairing|pairing-qr|devices|revoke-device ID|logs|check-update|update|enable-shutdown|disable-shutdown}' >&2; exit 2 ;;
esac
