#!/usr/bin/env python3
"""Use the repository VERSION as the single source for Flutter app versions."""
from pathlib import Path
import re

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
    pubspec = pubspec[:matches[0].start()] + f"version: {version}" + pubspec[matches[0].end():]
    pubspec_path.write_text(pubspec, encoding="utf-8")
    print(f"Synced Flutter app version: {installed} -> {version}")
else:
    print(f"Flutter app version matches VERSION: {version}")
