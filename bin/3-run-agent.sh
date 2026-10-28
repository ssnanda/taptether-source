#!/usr/bin/env bash
# Run the Go desktop agent from source.
# Usage: ./bin/3-run-agent.sh [agent arguments]
#   --help         Forwarded to the Go agent; inspect the agent's own flags.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/agent"
exec go run ./cmd/taptether-agent "$@"
