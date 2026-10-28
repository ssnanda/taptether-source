#!/usr/bin/env bash
# Run Go tests and Flutter analysis/tests when available.
# Usage: ./bin/9-test.sh [--help]
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,6p" "$0" | sed "s/^# //"; exit 0; fi
[[ $# -eq 0 ]] || { echo "Unknown option: $1" >&2; sed -n "2,6p" "$0" >&2; exit 2; }
(cd "$ROOT/agent" && go test ./... && go vet ./...)
if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/app" && flutter pub get && flutter analyze && flutter test)
else
  echo 'Flutter not installed; Go tests completed, Flutter checks skipped.'
fi
