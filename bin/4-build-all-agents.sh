#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for platform in macos ubuntu windows; do
  printf '\n===== BUILDING %s AGENT =====\n' "$platform"
  bash "$ROOT/bin/build-agent-$platform.sh"
done
printf '\n===== ALL DESKTOP AGENT BUILDS COMPLETE =====\n'
