#!/usr/bin/env bash
# Build macOS, Ubuntu, and Windows desktop agents in sequence.
# Usage: ./bin/4-build-all-agents.sh [--help]
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,6p" "$0" | sed "s/^# //"; exit 0; fi
[[ $# -eq 0 ]] || { echo "Unknown option: $1" >&2; sed -n "2,6p" "$0" >&2; exit 2; }
for platform in macos ubuntu windows; do
  printf '\n===== BUILDING %s AGENT =====\n' "$platform"
  bash "$ROOT/bin/4-build-agent-$platform.sh"
done
printf '\n===== ALL DESKTOP AGENT BUILDS COMPLETE =====\n'
