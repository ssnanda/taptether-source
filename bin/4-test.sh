#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/agent" && go test ./... && go vet ./...)
if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT/app" && flutter pub get && flutter analyze && flutter test)
else
  echo 'Flutter not installed; Go tests completed, Flutter checks skipped.'
fi
