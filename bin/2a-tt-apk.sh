#!/usr/bin/env bash
# Build and optionally publish the latest Android APK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2; exit 1; }
PUBLISH=1
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --no-publish|--local-only) PUBLISH=0; shift ;;
    *) break ;;
  esac
done
python3 "$ROOT/bin/9-tt-brand-icons.py"
cd "$ROOT/app"
flutter pub get
flutter analyze
"$ROOT/bin/2e-tt-stage-mobile-agents.sh"
flutter build apk --release "$@"
mkdir -p "$ROOT/dist/android"
VERSION="$(cat "$ROOT/VERSION")"
OUTPUT="$ROOT/dist/android/TapTether-$VERSION.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$OUTPUT"
find "$ROOT/dist/android" -maxdepth 1 -type f -name 'TapTether-*.apk' ! -name "$(basename "$OUTPUT")" -delete
echo "APK: $OUTPUT"
if [[ "$PUBLISH" -eq 1 ]]; then bash "$ROOT/bin/6-tt-publish-latest.sh"; fi
