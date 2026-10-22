#!/usr/bin/env bash
# Stage native Files/iCloud Drive directory access in Flutter-generated iOS.
# Combining into AppDelegate.swift avoids editing generated pbxproj references.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/app/ios/Runner"
if [[ ! -d "$IOS" ]]; then
  echo "No generated iOS Runner yet; stage after flutter create." >&2
  exit 1
fi
cp "$ROOT/bin/ios/AppDelegate.swift" "$IOS/AppDelegate.swift"
printf '\n' >> "$IOS/AppDelegate.swift"
cat "$ROOT/bin/ios/TapTetherCloudFolder.swift" >> "$IOS/AppDelegate.swift"
echo "Staged TapTether iCloud Drive folder picker and coordinated writer."
