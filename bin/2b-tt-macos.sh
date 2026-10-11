#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-agent.sh" darwin amd64
"$ROOT/bin/2b-tt-agent.sh" darwin arm64
