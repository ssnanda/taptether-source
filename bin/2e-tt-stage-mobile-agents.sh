#!/usr/bin/env bash
# Build native agents first, then stage checksummed installation archives as Flutter assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-ubuntu.sh"
if [[ "$(uname -s)" == Darwin ]]; then
  "$ROOT/bin/2b-tt-macos.sh"
else
  echo 'macOS native builds require Mac/Xcode. Staging existing same-version Mac archives if present.'
fi
python3 - "$ROOT" <<'TT_STAGE_PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile

root = Path(sys.argv[1])
version = (root / "VERSION").read_text().strip()
outdir = root / "app" / "assets" / "agents"
outdir.mkdir(parents=True, exist_ok=True)
for old in outdir.iterdir():
    if old.is_file() and old.name != ".gitkeep":
        old.unlink()

installers = []
for platform, suffix, folder, prefix in (
    ("ubuntu", ".deb", "ubuntu", "taptether-agent_"),
    ("macos", ".tar.gz", "macos", "TapTetherAgent-macos-"),
):
    for arch in ("amd64", "arm64"):
        if platform == "ubuntu":
            name = f"taptether-agent_{version}_{arch}.deb"
        else:
            name = f"TapTetherAgent-macos-{arch}-{version}.tar.gz"
        source = root / "dist" / folder / name
        if not source.is_file():
            if platform == "ubuntu":
                raise SystemExit(f"Required Ubuntu installer missing: {source}")
            print(f"macOS installer not available: {name}")
            continue
        if source.stat().st_size < 1024:
            raise SystemExit(f"Refusing empty/unrealistic installer: {source}")
        if platform == "ubuntu":
            if source.open("rb").read(8) != b"!<arch>\n":
                raise SystemExit(f"Invalid .deb archive: {source}")
        elif not tarfile.is_tarfile(source):
            raise SystemExit(f"Invalid macOS tar archive: {source}")
        destination = outdir / name
        shutil.copyfile(source, destination)
        installers.append({
            "platform": platform, "arch": arch,
            "filename": name, "asset": f"assets/agents/{name}",
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            "bytes": destination.stat().st_size,
        })
manifest = {"version": version, "installers": installers}
(outdir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Staged Flutter agent assets:")
for row in installers:
    print(f"  {row['platform']} {row['arch']}: {row['filename']} ({row['bytes']} bytes)")
TT_STAGE_PY
