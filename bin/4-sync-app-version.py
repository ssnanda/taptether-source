#!/usr/bin/env python3
"""Use the repository VERSION as the single source for Flutter app versions."""
from pathlib import Path
import re
import sys

CHECK_ONLY = '--check' in sys.argv[1:]
if len(sys.argv) > 2 or any(arg != '--check' for arg in sys.argv[1:]):
    raise SystemExit('Usage: python3 bin/4-sync-app-version.py [--check]')
ROOT = Path(__file__).resolve().parents[1]
version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+\+\d+", version):
    raise SystemExit(f"Invalid TapTether VERSION: {version!r}")

pubspec_path = ROOT / "app/pubspec.yaml"
pubspec = pubspec_path.read_text(encoding="utf-8")
matches = list(re.finditer(r"(?m)^version: ([^\r\n]+)$", pubspec))
if len(matches) != 1:
    raise SystemExit("Expected exactly one app/pubspec.yaml version field")
installed = matches[0].group(1).strip()
if installed != version:
    if CHECK_ONLY:
        raise SystemExit(
            f"Flutter version mismatch: app/pubspec.yaml={installed}; VERSION={version}. "
            "Run python3 bin/4-sync-app-version.py before building."
        )
    pubspec = pubspec[:matches[0].start()] + f"version: {version}" + pubspec[matches[0].end():]
    pubspec_path.write_text(pubspec, encoding="utf-8")
    print(f"Synced Flutter app version: {installed} -> {version}")
else:
    print(f"Flutter app version matches VERSION: {version}")
