#!/usr/bin/env bash
# Build Android APK locally without publishing.
# Usage: ./bin/4-build-android.sh [--help]
#   -h, --help     Show this help; other options forwarded to APK builder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "--help" ]] && { echo "Build Android APK locally; never publish."; exit 0; }
exec bash "$ROOT/bin/2a-tt-apk.sh" --no-publish "$@"
