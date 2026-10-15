#!/usr/bin/env bash
# Build testable no-SSH Windows agents and zip with local install helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/windows"
# Brand the Windows notification icon from the approved TapTether artwork.
python3 - "$ROOT" <<'PY'
import base64
from io import BytesIO
from pathlib import Path
import sys
from PIL import Image
root = Path(sys.argv[1])
source = root / 'assets/branding/app-icon.webp.b64'
picture = Image.open(BytesIO(base64.b64decode(source.read_text().strip())))
picture.convert('RGBA').save(root / 'dist/windows/TapTether.ico',
    format='ICO', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64)])
PY
for arch in amd64 arm64; do
  temp="$(mktemp -d)"
  (cd "$ROOT/agent" && CGO_ENABLED=0 GOOS=windows GOARCH="$arch" go build \
    -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$version" \
    -o "$temp/TapTetherAgent.exe" ./cmd/taptether-agent)
  cp "$ROOT/desktop/windows/"*.ps1 "$ROOT/desktop/windows/"*.cmd \
    "$ROOT/desktop/windows/README-Windows.txt" "$temp/"
  cp "$ROOT/VERSION" "$temp/version.txt"
  cp "$ROOT/dist/windows/TapTether.ico" "$temp/TapTether.ico"
  archive="$ROOT/dist/windows/TapTetherAgent-Windows-$arch-$version.zip"
  python3 - "$temp" "$archive" <<'PY'
from pathlib import Path
import sys,zipfile
source, dest = map(Path, sys.argv[1:])
with zipfile.ZipFile(dest, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as f:
    for item in sorted(source.iterdir()):
        f.write(item, item.name)
with zipfile.ZipFile(dest) as f:
    assert len(f.namelist()) == 13
    assert f.testzip() is None
print("Windows installer package:", dest)
PY
  rm -rf "$temp"
done
