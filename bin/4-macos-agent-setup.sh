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
  # Create a clickable branded Mac app launcher; the actual agent still runs under launchd.
  if [[ -s "$SELF/TapTether.icns" ]]; then
    local bundle="$HOME/Applications/TapTether Agent.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$SELF/TapTether.icns" "$bundle/Contents/Resources/TapTether.icns"
    cat > "$bundle/Contents/MacOS/TapTetherLauncher" <<'LAUNCHER'
#!/bin/bash
exec "$HOME/.local/bin/taptetherctl-mac" start
LAUNCHER
    chmod 755 "$bundle/Contents/MacOS/TapTetherLauncher"
    cat > "$bundle/Contents/Info.plist" <<'MACPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taptether.agent.launcher</string>
<key>CFBundleExecutable</key><string>TapTetherLauncher</string>
<key>CFBundleIconFile</key><string>TapTether.icns</string>
<key>CFBundleName</key><string>TapTether Agent</string>
<key>CFBundleDisplayName</key><string>TapTether Agent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
MACPLIST
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --deep --sign - --timestamp=none "$bundle" >/dev/null 2>&1 || true
    fi
    notice "Created branded app launcher: $bundle"
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
  sleep 2
  notice 'Background agent installed, started and enabled at login.'
  notice 'Allow TapTether in macOS System Settings > Privacy & Security > Accessibility to enable mouse/keyboard.'
  pairing
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
check_update() {
  [[ -f "$UPDATER" ]] || { notice 'Update helper missing; install the newest macOS agent archive.' >&2; exit 1; }
  bash "$UPDATER" check
}
update_agent() {
  [[ -f "$UPDATER" ]] || { notice 'Update helper missing; install the newest macOS agent archive.' >&2; exit 1; }
  bash "$UPDATER" update
}
case "$@" in
  install) install_agent ;;
  start) launchctl bootstrap "$TARGET" "$PLIST" 2>/dev/null || true; launchctl kickstart -k "$TARGET/$LABEL" ;;
  stop) launchctl bootout "$TARGET/$LABEL" ;;
  restart) launchctl kickstart -k "$TARGET/$LABEL" ;;
  status) launchctl print "$TARGET/$LABEL" ;;
  pairing) pairing ;;
  logs) tail -n 50 "$LOGDIR/agent.stderr.log" ;;
  check-update) check_update ;;
  update) update_agent ;;
  enable-shutdown) enable_shutdown ;;
  disable-shutdown) disable_shutdown ;;
  *) echo 'Usage: taptetherctl-mac {install|start|stop|restart|status|pairing|logs|check-update|update|enable-shutdown|disable-shutdown}' >&2; exit 2 ;;
esac
