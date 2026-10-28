#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -eq 0 || "${1:-}" == "--help" ]]; then
  echo "Usage: ./bin/5-install-agent-ubuntu.sh USER@HOST"
  exit "$([[ $# -gt 0 ]] && echo 0 || echo 2)"
fi
exec bash "$ROOT/bin/5-tt-remote-install-ubuntu.sh" "$@"
