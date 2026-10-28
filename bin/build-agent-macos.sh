#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "--help" ]] && { echo "Build macOS Intel/ARM desktop agent archives, locally only."; exit 0; }
[[ $# -eq 0 ]] || { echo "Unknown argument: $1" >&2; exit 2; }
exec bash "$ROOT/bin/2b-tt-macos.sh"
