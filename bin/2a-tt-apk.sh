#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2;exit 1; }
cd "$ROOT/app"
flutter pub get
flutter build apk --release "$@"
mkdir -p "$ROOT/dist/android"
version="$(cat "$ROOT/VERSION")"
cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/android/TapTether-${version}.apk"
echo "APK: $ROOT/dist/android/TapTether-${version}.apk"
