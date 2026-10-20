#!/usr/bin/env python3
"""Offline lifecycle regression: macOS agent recovery, manual Stop, core safety."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "4-macos-agent-setup.sh"
TRAY = (ROOT / "desktop" / "macos" / "TapTetherTray.swift").read_text()
SETUP_TEXT = SETUP.read_text()

def main():
    with tempfile.TemporaryDirectory(prefix="tt-mac-autorecover-") as root:
        home = Path(root)
        launcher = home / "fake-bin"
        launcher.mkdir()
        loaded = home / "loaded"
        running = home / "running"
        log = home / "launchctl.log"
        mock = launcher / "launchctl"
        mock.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$TT_LOG"
case "$1" in
  print)
    if [ -e "$TT_RUNNING" ]; then echo 'state = running'
    elif [ -e "$TT_LOADED" ]; then echo 'state = waiting'
    else exit 3
    fi ;;
  bootstrap) : > "$TT_LOADED" ;;
  kickstart) : > "$TT_LOADED"; : > "$TT_RUNNING" ;;
  bootout) rm -f "$TT_LOADED" "$TT_RUNNING" ;;
  *) exit 7 ;;
esac
""")
        mock.chmod(0o755)
        binary = home / ".local" / "bin" / "taptether-agent"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\\nexit 0\\n")
        binary.chmod(0o755)
        plist = home / "Library" / "LaunchAgents" / "com.taptether.agent.plist"
        plist.parent.mkdir(parents=True)
        plist.write_text("test-only")
        marker = home / "Library" / "Application Support" / "taptether" / "agent-stopped-by-user"
        env = {
            **os.environ,
            "HOME": str(home),
            "PATH": str(launcher) + os.pathsep + os.environ["PATH"],
            "TT_LOADED": str(loaded),
            "TT_RUNNING": str(running),
            "TT_LOG": str(log),
        }
        def call(action):
            return subprocess.run(["bash", str(SETUP), action],
                                  env=env, capture_output=True, text=True)
        first = call("ensure-running")
        assert first.returncode == 0, first.stderr
        assert loaded.exists() and running.exists()
        instructions = log.read_text()
        assert "bootstrap" in instructions and "kickstart" in instructions
        assert "input-core" not in instructions and "screen-core" not in instructions

        # Already running: never restart, repeatedly bootstrap, or touch cores.
        log.write_text("")
        assert call("ensure-running").returncode == 0
        assert log.read_text().count("print") == 1
        assert "kickstart" not in log.read_text()

        # Simulate launchd job unexpectedly disappearing after DHCP/sleep/login.
        running.unlink()
        loaded.unlink()
        log.write_text("")
        assert call("ensure-running").returncode == 0
        assert running.exists()
        assert "bootstrap" in log.read_text()
        assert "input-core" not in log.read_text()
        assert "screen-core" not in log.read_text()

        # A deliberate Stop is persistent; polling must never undo it.
        stop = call("stop")
        assert stop.returncode == 0, stop.stderr
        assert marker.is_file() and not running.exists()
        assert "input-core" not in log.read_text()
        assert "screen-core" not in log.read_text()
        log.write_text("")
        assert call("ensure-running").returncode == 0
        assert log.read_text() == ""
        assert not running.exists()

    # Source guards for explicit Start and bounded, silent tray recovery.
    start_body = SETUP_TEXT.split("start_agent() {", 1)[1].split(
        "ensure_agent_running() {", 1)[0]
    assert 'rm -f "$AGENT_STOPPED"' in start_body
    stop_body = SETUP_TEXT.split("stop_agent() {", 1)[1].split(
        "check_update() {", 1)[0]
    assert "CORE_LABEL" not in stop_body and "SCREEN_LABEL" not in stop_body
    assert '["ensure-running"]' in TRAY
    assert "recoveryInterval: TimeInterval = 300" in TRAY
    assert "deliberateStopMarker" in TRAY
    assert "recoverAgentIfNeeded()" in TRAY
    assert "NSAlert" not in TRAY.split("private func recoverAgentIfNeeded()", 1)[1].split(
        "private func showNotice(", 1)[0]
    print("PASS: launchd auto-recovery, manual Stop, bounded silent tray, protected cores")


if __name__ == "__main__":
    main()
