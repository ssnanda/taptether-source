#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo 'TapTether toolchain check'
for app in git flutter dart go python3; do
  if command -v "$app" >/dev/null 2>&1; then echo "OK: $app ($(command -v "$app"))"; else echo "MISSING: $app"; fi
done
if [[ "$(uname -s)" == Darwin ]]; then
  if command -v xcodebuild >/dev/null 2>&1; then echo 'OK: Xcode build tools'; else echo 'MISSING: Xcode build tools'; fi
  if command -v pod >/dev/null 2>&1; then echo 'OK: CocoaPods'; else echo 'MISSING: CocoaPods (may be required for iOS plugins)'; fi
fi
if [[ "$(uname -s)" == Linux ]]; then
  command -v xdotool >/dev/null 2>&1 && echo 'OK: xdotool' || echo 'MISSING: xdotool (sudo apt install xdotool)'
  [[ -n "${DISPLAY:-}" ]] && echo "X11 DISPLAY=${DISPLAY}" || echo 'No DISPLAY; Ubuntu input requires active X11 desktop'
fi
if [[ "${1:-}" == --repair ]]; then
  command -v flutter >/dev/null 2>&1 || { echo 'Install Flutter first' >&2; exit 1; }
  (cd app && flutter create --platforms=ios,android --org com.taptether --project-name taptether . && flutter pub get)
  echo 'Flutter native platform projects generated/repaired.'
fi
