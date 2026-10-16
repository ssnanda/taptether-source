#!/usr/bin/env python3
"""Cheap source-level invariants for the split macOS Input Core lifecycle."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / "bin/4-macos-agent-setup.sh").read_text()
BUILD = (ROOT / "bin/2b-tt-macos.sh").read_text()
TRAY = (ROOT / "desktop/macos/TapTetherTray.swift").read_text()
UPDATER = (ROOT / "bin/8-tt-update-macos.sh").read_text()
CLEANUP = (ROOT / "bin/4-clean-macos-review-apps.sh").read_text()
PUBLISH = (ROOT / "bin/6-tt-publish-latest.sh").read_text()

assert '[[ -x "$CORE" && -z "$requested" ]]' in SETUP
assert 'Preserved TapTether Input Core' in SETUP
assert 'upgrade-core)' in SETUP and '--authorize' in SETUP
assert 'com.taptether.input-core' in SETUP
assert 'ipc.token' in SETUP and 'chmod 600' in SETUP
assert 'launchctl bootout "$TARGET/$CORE_LABEL"' in SETUP
assert 'Preserved running Input Core service (no restart or re-sign)' in SETUP
assert 'Input Core $installed already approved; refusing needless replacement.' in SETUP
assert 'codesign --force --deep' not in BUILD
assert 'codesign --force --deep' not in SETUP
assert 'taptether-input-core' in BUILD
assert 'TapTetherInputCore-macos-' in BUILD
assert 'taptether-input-core' not in UPDATER  # routine updater is agent-only
assert 'taptether-input-core' in TRAY
assert 'coreRemaining' in TRAY
assert 'CANONICAL="$HOME/Applications/TapTether Agent.app"' in CLEANUP
assert "find \"$ROOT/dist\" -type d -name '*.app'" in CLEANUP
assert 'delete (POSIX file' in CLEANUP and 'rm -rf' not in CLEANUP
assert 'bash "$ROOT/bin/4-clean-macos-review-apps.sh"' in PUBLISH
print("PASS: stable Input Core preservation, no routine restart, no recursive signing,")
print("      complete Quit, agent-only updates, and review-app cleanup invariants")
