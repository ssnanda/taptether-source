#!/usr/bin/env bash
# Build testable no-SSH Windows agents and zip with local install helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/windows"
for arch in amd64 arm64; do
  temp="$(mktemp -d)"
  (cd "$ROOT/agent" && CGO_ENABLED=0 GOOS=windows GOARCH="$arch" go build \
    -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$version" \
    -o "$temp/TapTetherAgent.exe" ./cmd/taptether-agent)
  cp "$ROOT/desktop/windows/"*.ps1 "$ROOT/desktop/windows/"*.cmd \
    "$ROOT/desktop/windows/README-Windows.txt" "$temp/"
  cp "$ROOT/VERSION" "$temp/version.txt"
  archive="$ROOT/dist/windows/TapTetherAgent-Windows-$arch-$version.zip"
  python3 - "$temp" "$archive" <<'PY'
from pathlib import Path
import sys,zipfile
source, dest = map(Path, sys.argv[1:])
with zipfile.ZipFile(dest, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as f:
    for item in sorted(source.iterdir()):
        f.write(item, item.name)
with zipfile.ZipFile(dest) as f:
    assert len(f.namelist()) == 12
    assert f.testzip() is None
print("Windows installer package:", dest)
PY
  rm -rf "$temp"
done
