#!/usr/bin/env bash
# Build the experimental LG webOS companion package.
# Usage: ./bin/9-build-lg-companion.sh [--help]
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ ( "${1:-}" == "--help" || "${1:-}" == "-h" ) ]] && { echo "Build experimental LG webOS companion .ipk; not a TV input agent."; exit 0; }
[[ $# -eq 0 ]] || { echo "Unknown argument: $1" >&2; exit 2; }
exec bash "$ROOT/bin/2c-tt-lg-tv.sh"
