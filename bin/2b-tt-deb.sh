#!/usr/bin/env bash
# Portable Debian package builder: avoids macOS ar/ranlib's Mach-O symbol index.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required for .deb packaging.' >&2; exit 1; }
python3 - "$ROOT" <<'TT_DEB_PY'
from __future__ import annotations

import io
import os
from pathlib import Path
import re
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
version = (root / 'VERSION').read_text(encoding='utf-8').strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', version):
    raise SystemExit(f'Invalid package version: {version!r}')

output_dir = root / 'dist' / 'ubuntu'
output_dir.mkdir(parents=True, exist_ok=True)


def tar_gz(members):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz', format=tarfile.USTAR_FORMAT) as archive:
        for path, content, mode in members:
            entry = tarfile.TarInfo(path)
            entry.size = len(content)
            entry.mode = mode
            entry.uid = entry.gid = entry.mtime = 0
            entry.uname = entry.gname = 'root'
            archive.addfile(entry, io.BytesIO(content))
    return buffer.getvalue()


def write_ar_member(fh, name, data):
    if len(name) > 15:
        raise ValueError(f'Debian archive member name too long: {name}')
    header = (
        f'{name + "/":<16}'
        f'{0:<12}'
        f'{0:<6}'
        f'{0:<6}'
        f'{"100644":<8}'
        f'{len(data):<10}'
    ).encode('ascii') + bytes((96, 10))
    if len(header) != 60:
        raise AssertionError('Invalid ar header length')
    fh.write(header)
    fh.write(data)
    if len(data) % 2:
        fh.write(b'\n')


for arch in ('amd64', 'arm64'):
    binary_path = root / 'dist' / 'agents' / f'TapTetherAgent-linux-{arch}-{version}'
    if not binary_path.is_file():
        raise SystemExit(f'Missing {binary_path}; run ./bin/2b-tt-ubuntu.sh first')
    binary = binary_path.read_bytes()
    if len(binary) < 1024 or not binary.startswith(b'\x7fELF'):
        raise SystemExit(f'Not a plausible Linux ELF executable: {binary_path}')
    control = (
        'Package: taptether-agent\n'
        f'Version: {version}\n'
        'Section: utils\n'
        'Priority: optional\n'
        f'Architecture: {arch}\n'
        'Maintainer: TapTether <support@taptether.com>\n'
        'Depends: xdotool\n'
        'Description: TapTether local-first keyboard and trackpad agent\n'
        ' A local HTTPS remote input agent for an X11 Ubuntu desktop.\n'
        ' No cloud account or telemetry.\n'
    ).encode('utf-8')
    members = (
        ('debian-binary', b'2.0\n'),
        ('control.tar.gz', tar_gz([('control', control, 0o644)])),
        ('data.tar.gz', tar_gz([('usr/local/bin/taptether-agent', binary, 0o755)])),
    )
    output = output_dir / f'taptether-agent_{version}_{arch}.deb'
    fd, temp_path = tempfile.mkstemp(prefix=f'.taptether-{arch}-', suffix='.deb', dir=output_dir)
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(b'!<arch>\n')
            for name, data in members:
                write_ar_member(fh, name, data)
        if os.path.getsize(temp_path) < 1024:
            raise RuntimeError(f'Unexpectedly small package: {temp_path}')
        os.replace(temp_path, output)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print(f'Debian package: {output} ({output.stat().st_size:,} bytes)')
TT_DEB_PY
