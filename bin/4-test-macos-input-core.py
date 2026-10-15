#!/usr/bin/env python3
"""Cheap source-level invariants for the split macOS Input Core lifecycle."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / "bin/4-macos-agent-setup.sh").read_text()
BUILD = (ROOT / "bin/2b-tt-macos.sh").read_text()
TRAY = (ROOT / "desktop/macos/TapTetherTray.swift").read_text()
UPDATER = (ROOT / "bin/8-tt-update-macos.sh").read_text()

assert '[[ -x "$CORE" && -z "$requested" ]]' in SETUP
assert 'Preserved TapTether Input Core' in SETUP
assert 'upgrade-core)' in SETUP and '--authorize' in SETUP
assert 'com.taptether.input-core' in SETUP
assert 'ipc.token' in SETUP and 'chmod 600' in SETUP
assert 'launchctl bootout "$TARGET/$CORE_LABEL"' in SETUP
assert 'taptether-input-core' in BUILD
assert 'TapTetherInputCore-macos-' in BUILD
assert 'taptether-input-core' not in UPDATER  # routine updater is agent-only
assert 'taptether-input-core' in TRAY
assert 'coreRemaining' in TRAY
print("PASS: stable Input Core preservation, explicit upgrade, migration, diagnostics,")
print("      complete Quit, and agent-only updater invariants")
