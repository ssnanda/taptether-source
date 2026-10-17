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

# Native Ubuntu 26.10 crash regression: do not map raw RGB video frames,
# calculate stride in Python or call Pillow from GStreamer's streaming thread.
assert "GstVideo.VideoInfo(" not in text
assert 'gi.require_version("GstVideo"' not in text
assert "Image.frombytes" not in text
assert "buffer.map(" not in text
assert "buffer.unmap(" not in text
assert "buffer.extract_dup(0, size)" in text
assert "jpegenc quality=65" in text
assert "videoscale add-borders=true" in text
assert "video/x-raw,width=1280,height=720,format=I420" in text

# Exercise the actual Python JPEG-copy callback with a fake appsink sample:
# exact image data must remain in memory and malformed data must be rejected.
import threading
import time
from types import SimpleNamespace
method = next(n for n in service.body if isinstance(n, ast.FunctionDef)
              and n.name == "save_frame")
test_module = ast.Module(body=[method], type_ignores=[])
namespace = {
    "Gst": SimpleNamespace(FlowReturn=SimpleNamespace(OK=0)),
    "MAX_W": 1280, "MAX_H": 720, "MAX_JPEG": 2 << 20,
    "time": time,
}
exec(compile(ast.fix_missing_locations(test_module), str(path), "exec"),
     namespace)
def fake_sample(payload, media_type="image/jpeg"):
    class Buffer:
        def get_size(self): return len(payload)
        def extract_dup(self, off, size): return payload[off:off+size]
    class Caps:
        def get_size(self): return 1
        def get_structure(self, index):
            return SimpleNamespace(get_name=lambda: media_type)
    return SimpleNamespace(get_caps=Caps, get_buffer=Buffer)
class Service:
    def __init__(self):
        self.lock = threading.Lock()
        self.frame = None
        self.error = ""
        self.messages = []
    def log_error(self, text):
        self.messages.append(text)
save_frame = namespace["save_frame"]
service_instance = Service()
valid = b"\xff\xd8" + b"testjpeg" + b"\xff\xd9"
assert save_frame(service_instance, fake_sample(valid)) == 0
assert service_instance.frame[0:3] == (1280, 720, valid)
save_frame(service_instance, fake_sample(b"not jpeg"))
assert "rejected" in service_instance.error
assert len(service_instance.messages) == 1
save_frame(service_instance, fake_sample(b"\xff\xd8\xff\xd9", "video/x-raw"))
assert "Expected encoded JPEG" in service_instance.error
save_frame(service_instance, fake_sample(b"X" * ((2<<20)+1)))
assert "outside safe bounds" in service_instance.error

print("PASS: Ubuntu Live idle behavior and bounded native-JPEG frame handling")
