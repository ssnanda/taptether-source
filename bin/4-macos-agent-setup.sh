#!/usr/bin/env bash
# Install, start and manage TapTether as a background macOS LaunchAgent.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APP="$BIN/taptether-agent"
CTL="$BIN/taptetherctl-mac"
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
  mkdir -p "$BIN" "$(dirname "$PLIST")" "$LOGDIR"
  chmod 700 "$LOGDIR"
  if [[ "$SELF/taptether-agent" != "$APP" ]]; then
    [[ -x "$SELF/taptether-agent" ]] || { notice 'Run setup from extracted agent archive' >&2; exit 1; }
    cp "$SELF/taptether-agent" "$APP"
  fi
  if [[ "$0" != "$CTL" ]]; then cp "$0" "$CTL"; fi
  chmod 755 "$APP" "$CTL"
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
  launchctl bootout "$TARGET/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$TARGET" "$PLIST"
  launchctl kickstart -k "$TARGET/$LABEL"
  sleep 2
  notice 'Background agent installed, started and enabled at login.'
  notice 'Allow TapTether in macOS System Settings > Privacy & Security > Accessibility to enable mouse/keyboard.'
  pairing
}
case "$@" in
  install) install_agent ;;
  start) launchctl bootstrap "$TARGET" "$PLIST" 2>/dev/null || true; launchctl kickstart -k "$TARGET/$LABEL" ;;
  stop) launchctl bootout "$TARGET/$LABEL" ;;
  restart) launchctl kickstart -k "$TARGET/$LABEL" ;;
  status) launchctl print "$TARGET/$LABEL" ;;
  pairing) pairing ;;
  logs) tail -n 50 "$LOGDIR/agent.stderr.log" ;;
  *) echo 'Usage: taptetherctl-mac {install|start|stop|restart|status|pairing|logs}' >&2; exit 2 ;;
esac
