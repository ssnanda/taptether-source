#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-ubuntu.sh"
"$ROOT/bin/2b-tt-windows.sh"
"$ROOT/bin/2b-tt-macos.sh"
if command -v flutter >/dev/null 2>&1; then
  "$ROOT/bin/2a-tt-apk.sh"
  if [[ "$(uname -s)" == Darwin ]]; then
    "$ROOT/bin/2a-tt-ipa.sh"
  fi
else
  echo 'Flutter missing: mobile builds skipped.'
fi
echo 'All available TapTether artifacts are in dist/.'
