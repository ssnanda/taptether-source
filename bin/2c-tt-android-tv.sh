#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo 'Experimental Android TV APK: currently uses the mobile layout (not TV-optimized).'
"$ROOT/bin/2a-tt-apk.sh" "$@"
