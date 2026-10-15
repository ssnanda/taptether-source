#!/usr/bin/env python3
"""Offline regression tests for safe, per-user macOS TapTether uninstall."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "4-macos-agent-setup.sh"

def test_uninstall(mode: str, erase: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="taptether-mac-uninstall-") as tmp:
        home = Path(tmp)
        bin_dir = home / ".local" / "bin"
        agents = home / "Library" / "LaunchAgents"
        logs = home / "Library" / "Logs" / "TapTether"
        conf = home / "Library" / "Application Support" / "taptether"
        bundle = home / "Applications" / "TapTether Agent.app"
        files = [
            bin_dir / "taptether-agent",
            bin_dir / "taptetherctl-mac",
            bin_dir / "taptether-agent-update-mac",
            agents / "com.taptether.agent.plist",
            agents / "com.taptether.tray.plist",
            logs / "agent.stderr.log",
            bundle / "Contents" / "Info.plist",
            conf / "pairing.token",
            conf / "server.crt",
            conf / "server.key",
            conf / "authorized_devices.json",
            conf / "remote-shutdown-disabled",
        ]
        for path in files:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture-only", encoding="utf-8")
        unrelated = home / "Library" / "LaunchAgents" / "com.some.other.app.plist"
        unrelated.write_text("leave alone", encoding="utf-8")
        env = {**os.environ, "HOME": str(home)}
        # No mode means no deletion, even if user has triggered the script.
        invalid = subprocess.run(
            ["bash", str(SETUP), "uninstall"],
            env=env, capture_output=True, text=True, check=False)
        if os.geteuid() == 0:
            assert invalid.returncode != 0  # root uninstall is forbidden
            return
        assert invalid.returncode == 2, invalid.stderr
        assert all(path.exists() for path in files)
        result = subprocess.run(
            ["bash", str(SETUP), "uninstall", mode],
            env=env, capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stderr
        assert unrelated.read_text(encoding="utf-8") == "leave alone"
        assert not (bin_dir / "taptether-agent").exists()
        assert not (bin_dir / "taptetherctl-mac").exists()
        assert not (bin_dir / "taptether-agent-update-mac").exists()
        assert not (agents / "com.taptether.agent.plist").exists()
        assert not (agents / "com.taptether.tray.plist").exists()
        assert not logs.exists()
        assert not bundle.exists()
        assert conf.exists() is (not erase)

if __name__ == "__main__":
    test_uninstall("--keep-pairing", False)
    test_uninstall("--erase-pairing", True)
    print("PASS: macOS uninstall requires explicit mode, is scoped to TapTether,")
    print("      and retains or permanently removes pairing only as requested")
