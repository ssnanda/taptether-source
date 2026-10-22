#!/usr/bin/env bash
# Build and optionally publish the latest iOS IPA. --no-publish skips GitHub upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'IPA builds require macOS with Xcode.' >&2; exit 1; }
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.' >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo 'Xcode not found.' >&2; exit 1; }
PUBLISH=1
SIGNED=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --no-publish|--local-only) PUBLISH=0; shift ;;
    --unsigned) shift ;;
    --signed) SIGNED=1; shift ;;
    *) break ;;
  esac
done
python3 "$ROOT/bin/9-tt-brand-icons.py"
python3 "$ROOT/bin/4-sync-app-version.py"
cd "$ROOT/app"
flutter pub get
bash "$ROOT/bin/2f-tt-ios-cloud-backup.sh"
# Fail immediately on invalid Dart instead of after agent compilation/Xcode packaging.
flutter analyze
"$ROOT/bin/2e-tt-stage-mobile-agents.sh"
VERSION="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/ios"
if [[ "$SIGNED" -eq 1 ]]; then
  flutter build ipa --release "$@"
  BUILT="$(find "$ROOT/app/build/ios/ipa" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
  [[ -s "$BUILT" ]] || { echo 'Signed IPA missing.' >&2; exit 1; }
  OUTPUT="$ROOT/dist/ios/TapTether-$VERSION.ipa"
  cp "$BUILT" "$OUTPUT"
else
  flutter build ios --release --no-codesign "$@"
  [[ -d build/ios/iphoneos/Runner.app ]] || { echo 'Runner.app missing.' >&2; exit 1; }
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/Payload"
  cp -R build/ios/iphoneos/Runner.app "$TMP/Payload/"
  OUTPUT="$ROOT/dist/ios/TapTether-$VERSION-unsigned.ipa"
  rm -f "$OUTPUT"
  (cd "$TMP" && /usr/bin/zip -qry "$OUTPUT" Payload)
  echo 'Unsigned IPA requires AltStore or other valid signing before sideloading.'
fi
# Keep only the current version's local IPA packages.
find "$ROOT/dist/ios" -maxdepth 1 -type f -name 'TapTether-*.ipa' ! -name "$(basename "$OUTPUT")" -delete
echo "IPA: $OUTPUT"
python3 "$ROOT/bin/6-tt-generate-altstore.py" \
  --ipa "$OUTPUT" --version-file "$ROOT/VERSION" \
  --output "$ROOT/altstore.json" --icon-output "$ROOT/dist/release/TapTether-icon.png"
echo "AltStore source: $ROOT/altstore.json"
if [[ "$PUBLISH" -eq 1 ]]; then bash "$ROOT/bin/6-tt-publish-latest.sh"; fi
