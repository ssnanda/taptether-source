#!/usr/bin/env python3
"""Offline audit of the exact desktop files included in release installers."""
from __future__ import annotations

import argparse
import io
from pathlib import Path
import tarfile


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def ar_members(path: Path) -> dict[str, bytes]:
    with path.open('rb') as stream:
        require(stream.read(8) == b'!<arch>\n', f'{path}: invalid Debian archive')
        members = {}
        while header := stream.read(60):
            require(len(header) == 60 and header[58:60] == bytes((96, 10)), f'{path}: malformed ar header')
            name = header[:16].decode('ascii').strip().rstrip('/')
            size = int(header[48:58].decode('ascii').strip())
            members[name] = stream.read(size)
            require(len(members[name]) == size, f'{path}: truncated ar member {name}')
            if size % 2:
                require(len(stream.read(1)) == 1, f'{path}: missing ar padding')
    return members


def check_deb(root: Path, version: str, arch: str) -> None:
    archive = root / 'dist' / 'ubuntu' / f'taptether-agent_{version}_{arch}.deb'
    require(archive.is_file(), f'Missing Ubuntu package: {archive}')
    ar = ar_members(archive)
    require({'debian-binary', 'control.tar.gz', 'data.tar.gz'} <= ar.keys(), f'{archive}: missing required sections')
    with tarfile.open(fileobj=io.BytesIO(ar['control.tar.gz']), mode='r:gz') as tf:
        control = tf.extractfile('control').read().decode('utf-8')
    for line in ('Package: taptether-agent', f'Version: {version}', f'Architecture: {arch}'):
        require(line in control.splitlines(), f'{archive}: incorrect package metadata: {line}')
    sources = {
        'usr/share/taptether/4-ubuntu-desktop-setup.sh': root / 'bin' / '4-ubuntu-desktop-setup.sh',
        'usr/share/taptether/7-tt-update-ubuntu.sh': root / 'bin' / '7-tt-update-ubuntu.sh',
        'usr/share/taptether/taptether_tray.py': root / 'desktop' / 'ubuntu' / 'taptether_tray.py',
    }
    expected = {'usr/local/bin/taptether-agent', 'usr/bin/taptether-setup',
                'usr/share/taptether/TapTether-icon.png', *sources.keys()}
    with tarfile.open(fileobj=io.BytesIO(ar['data.tar.gz']), mode='r:gz') as tf:
        entries = {m.name: m for m in tf.getmembers() if m.isfile()}
        require(expected <= entries.keys(), f'{archive}: missing payload: {sorted(expected - entries.keys())}')
        for package_name, source in sources.items():
            require(tf.extractfile(entries[package_name]).read() == source.read_bytes(),
                    f'{archive}: outdated bundled helper {package_name}')
        icon = tf.extractfile(entries['usr/share/taptether/TapTether-icon.png']).read()
        require(icon.startswith(b'\x89PNG\r\n\x1a\n'), f'{archive}: invalid icon')
        setup = tf.extractfile(entries['usr/bin/taptether-setup']).read()
        require(b'/usr/share/taptether/4-ubuntu-desktop-setup.sh' in setup,
                f'{archive}: setup command does not invoke packaged installer')
        for entry in expected:
            if entry != 'usr/share/taptether/TapTether-icon.png':
                require(entries[entry].mode & 0o111 != 0,
                        f'{archive}: required executable permission missing for {entry}')
    print(f'PASS Ubuntu {arch}: executable, desktop setup, tray, icon and updater packaged')


def check_macos(root: Path, version: str, arch: str) -> None:
    archive = root / 'dist' / 'macos' / f'TapTetherAgent-macos-{arch}-{version}.tar.gz'
    require(archive.is_file(), f'Missing macOS archive: {archive}')
    expected = {'taptether-agent', 'taptetherctl-mac', 'taptether-agent-update-mac',
                'TapTether.icns', 'TapTetherTray'}
    with tarfile.open(archive, mode='r:gz') as tf:
        entries = {m.name: m for m in tf.getmembers()}
        require(entries.keys() == expected, f'{archive}: unexpected/missing archive items: {sorted(entries.keys() ^ expected)}')
        for name in expected:
            require(entries[name].isfile() and entries[name].size > 100,
                    f'{archive}: invalid payload {name}')
            if name not in ('TapTether.icns',):
                require(entries[name].mode & 0o111 != 0, f'{archive}: {name} is not executable')
        for name, source in (
            ('taptetherctl-mac', root / 'bin' / '4-macos-agent-setup.sh'),
            ('taptether-agent-update-mac', root / 'bin' / '8-tt-update-macos.sh'),
        ):
            require(tf.extractfile(entries[name]).read() == source.read_bytes(),
                    f'{archive}: outdated helper {name}')
    print(f'PASS macOS {arch}: native tray, controller, updater, icon and agent packaged')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=('ubuntu', 'macos', 'all'), default='all')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = (root / 'VERSION').read_text(encoding='utf-8').strip()
    for arch in ('amd64', 'arm64'):
        if args.platform in ('ubuntu', 'all'):
            check_deb(root, version, arch)
        if args.platform in ('macos', 'all'):
            check_macos(root, version, arch)


if __name__ == '__main__':
    main()
