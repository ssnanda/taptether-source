#!/usr/bin/env bash
# Build Windows desktop agent packages locally.
# Usage: ./bin/4-build-agent-windows.sh [--help]
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ ( "${1:-}" == "--help" || "${1:-}" == "-h" ) ]] && { echo "Build Windows amd64/arm64 .zip installers, locally only."; exit 0; }
[[ $# -eq 0 ]] || { echo "Unknown argument: $1" >&2; exit 2; }
exec bash "$ROOT/bin/2c-tt-windows.sh"
