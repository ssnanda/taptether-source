#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "--help" ]] && { echo "Build Windows amd64/arm64 .zip installers, locally only."; exit 0; }
[[ $# -eq 0 ]] || { echo "Unknown argument: $1" >&2; exit 2; }
exec bash "$ROOT/bin/2c-tt-windows.sh"
