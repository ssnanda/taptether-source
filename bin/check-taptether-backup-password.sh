#!/usr/bin/env bash
# TapTether backup password verification. Local-only, read-only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3 is required to check .ttbackup files.' >&2
  exit 2
fi
exec python3 "$SCRIPT_DIR/check-taptether-backup-password.py" "$@"
