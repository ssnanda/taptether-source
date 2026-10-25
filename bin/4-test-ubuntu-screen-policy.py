#!/usr/bin/env python3
"""Ubuntu tray owner permission must block both Live and Snapshot at the agent.

Pure-function smoke tests deliberately do not require a GUI session or import
PyGObject; system tests then exercise the real Go Linux capture policy.
"""
import ast
import os
from pathlib import Path
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[1]
tray = (root / "desktop/ubuntu/taptether_tray.py").read_text()
helper = (root / "desktop/ubuntu/taptether_screen.py").read_text()
agent = (root / "agent/cmd/taptether-agent/screen_http.go").read_text()
info = (root / "agent/cmd/taptether-agent/main.go").read_text()
linux = (root / "agent/internal/screencap/capture_linux.go").read_text()
policy = (root / "agent/internal/screencap/policy_linux.go").read_text()
for text in (tray, helper):
    ast.parse(text)
assert 'SCREEN_DISABLED = Path.home() / ".config" / "taptether" / "screen-sharing-disabled"' in tray
assert 'SCREEN_DISABLED = STATE_DIR / "screen-sharing-disabled"' in helper
assert 'sharing = Gtk.CheckMenuItem(label="Allow screen sharing (Snapshot / Live)")' in tray
assert 'shutdown = Gtk.CheckMenuItem(label="Allow remote shutdown")' in tray
assert 'm.append(shutdown)' in tray
assert 'shutdown_policy_ready()' in tray
assert 'change_shutdown_preference(requested)' in tray
assert 'open_shutdown_setup()' in tray
assert 'shutdown.handler_block_by_func(change_shutdown)' in tray
assert 'enable-shutdown' in tray
assert 'screen_request(b"D")' in tray
assert 'if not sharing_allowed():' in helper
assert 'GLib.idle_add(self.disable_capture)' in helper
assert 'self.close_stream()' in helper
assert 'if !screencap.PolicyAllowed() {' in agent
assert 'http.StatusForbidden' in agent
assert 'if !screencap.PolicyAllowed() { return }' in agent
assert '"screenCaptureSupported": screencap.Available() && screencap.PolicyAllowed()' in info
assert 'if !PolicyAllowed() {' in linux
assert '"screen-sharing-disabled"' in policy

parsed = ast.parse(tray)
functions = {n.name: n for n in parsed.body if isinstance(n, ast.FunctionDef)}
required = ("screen_sharing_allowed", "change_screen_sharing_policy")
assert all(x in functions for x in required)
mod = ast.fix_missing_locations(ast.Module(body=[functions[x] for x in required], type_ignores=[]))
with TemporaryDirectory() as home:
    disabled = Path(home) / ".config" / "taptether" / "screen-sharing-disabled"
    commands = []
    names = {"SCREEN_DISABLED": disabled, "os": os, "screen_request": commands.append}
    exec(compile(mod, "taptether-tray-policy", "exec"), names)
    allowed, change = names["screen_sharing_allowed"], names["change_screen_sharing_policy"]
    assert allowed()
    change(False)
    assert not allowed()
    assert disabled.stat().st_mode & 0o777 == 0o600
    assert commands == [b"D"]
    change(False)
    assert not allowed()
    change(True)
    assert allowed()
    assert not disabled.exists()
print("PASS Ubuntu persistent Screen Helper tray toggle and agent-level sharing enforcement")
