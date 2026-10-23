#!/usr/bin/env python3
"""Offline owner-uninstall tests: fake polkit, no sudo or system changes."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "bin" / "4-ubuntu-uninstall.sh"


def run_case(mode, erase):
    with tempfile.TemporaryDirectory(prefix="taptether-uninstall-test-") as tmp:
        base = Path(tmp)
        home, mock_bin = base / "home", base / "mock-bin"
        home.mkdir()
        mock_bin.mkdir()
        log = base / "calls.txt"
        pkexec = mock_bin / "pkexec"
        pkexec.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TAPTETHER_TEST_CALLS"\nexit 0\n')
        pkexec.chmod(0o755)
        service = mock_bin / "systemctl"
        service.write_text('#!/bin/sh\nexit 0\n')
        service.chmod(0o755)
        files = (
            ".local/bin/taptetherctl",
            ".local/bin/taptether-uninstall",
            ".local/share/taptether/taptether_tray.py",
            ".config/autostart/taptether-tray.desktop",
            ".config/systemd/user/taptether-screen.service",
            ".cache/taptether/screen-helper.log",
            ".config/taptether/pairing.token",
            ".config/taptether/server.key",
        )
        for name in files:
            path = home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture-only")
        unrelated = home / ".config/unrelated-app/config.json"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("must remain")
        env = {**os.environ, "HOME": str(home),
               "PATH": str(mock_bin) + ":" + os.environ["PATH"],
               "TAPTETHER_TEST_CALLS": str(log)}
        def run(*args):
            return subprocess.run(["bash", str(SOURCE), *args], env=env,
                                  capture_output=True, text=True, check=False)
        assert run().returncode != 0
        assert run("--erase-pairing", "extra").returncode != 0
        assert (home / files[0]).exists()
        pkexec.write_text('#!/bin/sh\nexit 1\n')
        assert run(mode).returncode != 0
        assert (home / files[0]).exists()
        assert (home / files[-1]).exists()
        pkexec.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TAPTETHER_TEST_CALLS"\nexit 0\n')
        assert run(mode).returncode == 0
        for name in files:
            file = home / name
            if name.startswith(".config/taptether/") and not erase:
                assert file.exists(), name
            else:
                assert not file.exists(), name
        assert unrelated.read_text() == "must remain"
        assert log.read_text().strip() == (
            "/bin/bash /usr/share/taptether/4-ubuntu-uninstall.sh --system"
        )


if __name__ == "__main__":
    if os.geteuid() == 0:
        print("SKIP: tests require nonroot user")
    else:
        run_case("--keep-pairing", False)
        run_case("--erase-pairing", True)
        print("PASS: Ubuntu uninstall requires authorization and respects pairing choice")
