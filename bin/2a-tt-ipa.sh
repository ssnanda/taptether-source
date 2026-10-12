#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'IPA builds require macOS with Xcode.' >&2;exit 1; }
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2;exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo 'Xcode not found.' >&2;exit 1; }
"$ROOT/bin/2e-tt-stage-mobile-agents.sh"
cd "$ROOT/app"
flutter pub get
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/ios"
if [[ "${1:-}" == --signed ]]; then
  shift
  flutter build ipa --release "$@"
  echo 'Signed IPA (requires configured Apple signing): app/build/ios/ipa/'
else
  [[ "${1:-}" == --unsigned ]] && shift
  flutter build ios --release --no-codesign "$@"
  [[ -d build/ios/iphoneos/Runner.app ]] || { echo 'Runner.app missing.' >&2;exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Payload"
  cp -R build/ios/iphoneos/Runner.app "$tmp/Payload/"
  output="$ROOT/dist/ios/TapTether-${version}-unsigned.ipa"
  (cd "$tmp" && /usr/bin/zip -qry "$output" Payload)
  echo "Unsigned IPA: $output"
  echo 'Unsigned IPA requires external signing (for example AltStore) before installation on iPhone.'
fi
