#!/usr/bin/env bash
# Build macOS Intel/Apple Silicon desktop agent bundles locally.
# Usage: ./bin/4-build-agent-macos.sh [--help]
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ ( "${1:-}" == "--help" || "${1:-}" == "-h" ) ]] && { echo "Build macOS Intel/ARM desktop agent archives, locally only."; exit 0; }
[[ $# -eq 0 ]] || { echo "Unknown argument: $1" >&2; exit 2; }
exec bash "$ROOT/bin/2b-tt-macos.sh"
