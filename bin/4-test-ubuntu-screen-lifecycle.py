#!/usr/bin/env python3
"""Regression guards: GNOME GStreamer helper must not spin a GLib idle loop.

Gst.StateChangeReturn.SUCCESS and ASYNC are true when interpreted as bool.
Passing GstPipeline.set_state directly to GLib.idle_add repeats it forever
and can starve the ScreenCast portal and main event loop. This test checks
the Python source without requiring a logged-in Ubuntu/PipeWire session.
"""
from __future__ import annotations
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "desktop" / "ubuntu" / "taptether_screen.py"
text = path.read_text(encoding="utf-8")
tree = ast.parse(text)

assert "GLib.idle_add(pipeline.set_state" not in text, (
    "GStreamer StateChangeReturn is truthy; idle_add must use a one-shot wrapper"
)
assert "GLib.idle_add(self.resume_pipeline_once, pipeline)" in text

service = next(
    node for node in tree.body if isinstance(node, ast.ClassDef)
    and node.name == "ScreenService"
)
once = next(
    node for node in service.body if isinstance(node, ast.FunctionDef)
    and node.name == "resume_pipeline_once"
)
assert once.body[-1].__class__ is ast.Return
assert isinstance(once.body[-1].value, ast.Constant)
assert once.body[-1].value.value is False, (
    "GLib idle callback must always return False, regardless of GStreamer result"
)
assert 'self.log_error(self.error)' in text
assert 'self.log_error("ScreenCast startup failed: "' in text
assert 'inactive = time.monotonic() - self.last_request > 35' in text
assert 'GLib.timeout_add_seconds(3, service.check_idle)' in text

print("PASS: Ubuntu Live resumes once per frame; expected idle pause retained")
