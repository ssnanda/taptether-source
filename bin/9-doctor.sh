#!/usr/bin/env bash
# Check local development prerequisites; optionally generate Flutter platforms.
# Usage: ./bin/9-doctor.sh [--repair] [--help]
#   --repair       Generate/repair Flutter iOS and Android projects.
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,7p" "$0" | sed "s/^# //"; exit 0; fi
[[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == --repair ) ]] || { echo "Unknown option: ${1:-}" >&2; sed -n "2,7p" "$0" >&2; exit 2; }
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
