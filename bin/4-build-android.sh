#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "--help" ]] && { echo "Build Android APK locally; never publish."; exit 0; }
exec bash "$ROOT/bin/2a-tt-apk.sh" --no-publish "$@"
