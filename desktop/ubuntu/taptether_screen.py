#!/usr/bin/python3
"""TapTether Ubuntu screen source: owner-consented, in-memory LAN preview.

Runs ONLY in the logged-in desktop user's session. Snapshot and Live both read
the latest JPEG through a private same-UID Unix socket; no frames are written
to disk or sent to an external server. Ubuntu GNOME Wayland uses the standard
ScreenCast portal + PipeWire; X11 uses GStreamer ximagesrc.
"""
import io
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import sys
import threading
import time
import uuid
from urllib.parse import urlparse

try:
    import gi
    gi.require_version("Gst", "1.0")
    gi.require_version("GstVideo", "1.0")
    from gi.repository import Gio, GLib, Gst, GstVideo
    from PIL import Image
except (ImportError, ValueError) as exc:
    sys.exit("TapTether screen: missing GStreamer/PipeWire/Pillow packages: " + str(exc))

MAX_W, MAX_H = 1280, 720
MAX_JPEG = 2 << 20
PORTAL = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
SC = "org.freedesktop.portal.ScreenCast"
RUNTIME = Path("/run/user") / str(os.getuid())
SOCKET = RUNTIME / "taptether-screen.sock"
STATE_DIR = Path.home() / ".config" / "taptether"
TOKEN = STATE_DIR / "screen-restore.token"


class ScreenService:
    def __init__(self):
        self.lock = threading.Lock()
        self.frame = None
        self.error = "Screen sharing is starting. Approve the Ubuntu prompt if shown."
        self.last_request = 0.0
        self.launching = False
        self.pipeline = None
        self.session = None
        self.bus = None
        self.fd = None
        self.mainloop = GLib.MainLoop()

    def save_frame(self, sample):
        try:
            caps = sample.get_caps()
            info = GstVideo.VideoInfo()
            if not info.from_caps(caps):
                return Gst.FlowReturn.OK
            width, height = int(info.width), int(info.height)
            if not 0 < width <= 16384 or not 0 < height <= 16384:
                return Gst.FlowReturn.OK
            buffer = sample.get_buffer()
            ok, mapped = buffer.map(Gst.MapFlags.READ)
            if not ok:
                return Gst.FlowReturn.OK
            try:
                picture = Image.frombytes("RGB", (width, height),
                                          bytes(mapped.data), "raw", "RGB",
                                          info.stride[0])
                picture.thumbnail((MAX_W, MAX_H), getattr(Image, "Resampling", Image).BILINEAR)
                output = io.BytesIO()
                picture.save(output, "JPEG", quality=65)
            finally:
                buffer.unmap(mapped)
            jpeg = output.getvalue()
            if len(jpeg) > MAX_JPEG:
                return Gst.FlowReturn.OK
            with self.lock:
                self.frame = (picture.width, picture.height, jpeg, time.monotonic())
                self.error = ""
        except Exception as exc:
            with self.lock:
                self.error = "Ubuntu video frame conversion failed: " + str(exc)
        return Gst.FlowReturn.OK

    def portal_request(self, method, arguments):
        # Subscribe BEFORE making the request. Some portals finish
        # CreateSession immediately, before call_sync returns the handle.
        response = [None]
        handle = [None]
        early = {}
        nested = GLib.MainLoop()

        def receive(_bus, _sender, object_path, _interface, _signal, params):
            item = params.unpack()
            if handle[0] is None:
                early[object_path] = item
            elif object_path == handle[0]:
                response[0] = item
                nested.quit()

        subscription = self.bus.signal_subscribe(
            PORTAL, "org.freedesktop.portal.Request", "Response", None,
            None, Gio.DBusSignalFlags.NONE, receive)
        timer = None
        try:
            handle[0] = self.bus.call_sync(
                PORTAL, PATH, SC, method, arguments, GLib.VariantType("(o)"),
                Gio.DBusCallFlags.NONE, 120000, None).unpack()[0]
            response[0] = early.get(handle[0])
            if response[0] is None:
                def timeout():
                    nested.quit()
                    return False
                timer = GLib.timeout_add_seconds(110, timeout)
                nested.run()
        finally:
            self.bus.signal_unsubscribe(subscription)
            if timer is not None and response[0] is not None:
                GLib.source_remove(timer)
        if response[0] is None:
            raise RuntimeError("Ubuntu screen sharing approval timed out")
        status, result = response[0]
        if status != 0:
            raise RuntimeError("Screen sharing was cancelled or denied on Ubuntu")
        return result

    def launch_portal(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        name = uuid.uuid4().hex
        result = self.portal_request("CreateSession",
            GLib.Variant("(a{sv})", ({
                "handle_token": GLib.Variant("s", "tt" + name),
                "session_handle_token": GLib.Variant("s", "session" + name),
            },)))
        self.session = result["session_handle"]
        options = {
            "handle_token": GLib.Variant("s", "tt" + uuid.uuid4().hex),
            "types": GLib.Variant("u", 1),  # monitor, not an app window
            "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", 2),  # embedded pointer
            "persist_mode": GLib.Variant("u", 2),
        }
        try:
            saved = TOKEN.read_text(encoding="ascii").strip()
            if 0 < len(saved) <= 4096:
                options["restore_token"] = GLib.Variant("s", saved)
        except OSError:
            pass
        self.portal_request("SelectSources",
            GLib.Variant("(oa{sv})", (self.session, options)))
        started = self.portal_request("Start",
            GLib.Variant("(osa{sv})", (
                self.session, "", {
                    "handle_token": GLib.Variant("s", "tt" + uuid.uuid4().hex),
                })))
        streams = started.get("streams", ())
        if not streams:
            raise RuntimeError("Ubuntu ScreenCast portal returned no monitor")
        node = int(streams[0][0])
        restore = started.get("restore_token")
        if isinstance(restore, str) and 0 < len(restore) <= 4096:
            STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
            TOKEN.write_text(restore, encoding="ascii")
            TOKEN.chmod(0o600)
        response, handles = self.bus.call_with_unix_fd_list_sync(
            PORTAL, PATH, SC, "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (self.session, {})),
            GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, 30000,
            None, None)
        self.fd = handles.get(response.unpack()[0])
        return "pipewiresrc fd=%d path=%d do-timestamp=true" % (self.fd, node)

    def start(self):
        with self.lock:
            if self.pipeline is not None:
                self.pipeline.set_state(Gst.State.PLAYING)
                self.launching = False
                return False
        try:
            if os.environ.get("XDG_SESSION_TYPE", "").lower() == "x11":
                if not os.environ.get("DISPLAY"):
                    raise RuntimeError("DISPLAY is unavailable in the X11 desktop session")
                source = "ximagesrc use-damage=false show-pointer=true"
            else:
                source = self.launch_portal()
            pipeline = Gst.parse_launch(
                source + " ! queue leaky=downstream max-size-buffers=1 "
                "! videorate ! video/x-raw,framerate=12/1 "
                "! videoconvert ! video/x-raw,format=RGB "
                "! appsink name=screen sync=false emit-signals=true "
                "max-buffers=1 drop=true")
            sink = pipeline.get_by_name("screen")
            sink.connect("new-sample", lambda item: self.save_frame(item.emit("pull-sample")))
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.pipeline_error)
            bus.connect("message::eos", self.pipeline_error)
            pipeline.set_state(Gst.State.PLAYING)
            with self.lock:
                self.pipeline = pipeline
                self.error = ""
        except Exception as exc:
            with self.lock:
                self.error = str(exc)[:180]
            self.close_stream()
        finally:
            with self.lock:
                self.launching = False
        return False

    def pipeline_error(self, _bus, msg):
        detail = msg.parse_error()[0].message if msg.type == Gst.MessageType.ERROR else "ended"
        with self.lock:
            self.error = "Ubuntu screen stream stopped: " + detail[:160]
            self.frame = None
        self.close_stream()

    def close_stream(self):
        pipeline = self.pipeline
        self.pipeline = None
        if pipeline is not None:
            pipeline.set_state(Gst.State.NULL)
        if self.session and self.bus:
            try:
                self.bus.call_sync(PORTAL, self.session,
                    "org.freedesktop.portal.Session", "Close", None, None,
                    Gio.DBusCallFlags.NONE, 3000, None)
            except GLib.Error:
                pass
        self.session = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def check_idle(self):
        with self.lock:
            inactive = time.monotonic() - self.last_request > 35
            pipeline = self.pipeline
        if pipeline is not None and inactive:
            # Portal consent remains; no screen pixels are captured at rest.
            pipeline.set_state(Gst.State.PAUSED)
        return True

    def open_media(self, client):
        # Desktop browser actions are initiated only by the already paired
        # agent, through the private same-UID socket; never invoke a shell.
        address = bytearray()
        while len(address) < 300:
            data = client.recv(1)
            if data == b"\n":
                break
            if not data:
                return
            address.extend(data)
        try:
            uri = address.decode("ascii")
            parsed = urlparse(uri)
            if (parsed.scheme != "https" or parsed.username or parsed.password
                    or parsed.port is not None or parsed.fragment
                    or parsed.hostname not in ("www.youtube.com", "www.netflix.com")
                    or len(uri) > 256):
                raise ValueError("Media destination is not allowed")
            if parsed.hostname == "www.youtube.com" and parsed.path not in ("", "/", "/results"):
                raise ValueError("Invalid YouTube path")
            if parsed.hostname == "www.netflix.com" and parsed.path not in ("", "/", "/search"):
                raise ValueError("Invalid Netflix path")
            done = threading.Event()
            answer = [False]
            def dispatch():
                try:
                    Gio.AppInfo.launch_default_for_uri(uri, None)
                    answer[0] = True
                except GLib.Error:
                    pass
                done.set()
                return False
            GLib.idle_add(dispatch)
            if not done.wait(timeout=6):
                raise RuntimeError("Ubuntu graphical browser unavailable")
            client.sendall(b"Y" if answer[0] else b"N")
        except (ValueError, UnicodeError, OSError, RuntimeError):
            client.sendall(b"N")

    def respond(self, client):
        try:
            credentials = client.getsockopt(socket.SOL_SOCKET,
                                             socket.SO_PEERCRED, 12)
            _pid, uid, _gid = struct.unpack("3i", credentials)
            if uid != os.getuid():
                return
            client.settimeout(9)
            request = client.recv(1)
            if request == b"O":
                self.open_media(client)
                return
            if request != b"G":
                return  # Capability probe must not request screen permission.
            with self.lock:
                self.last_request = time.monotonic()
                launching = self.launching
                pipeline = self.pipeline
                if pipeline is None and not launching:
                    self.launching = True
                    GLib.idle_add(self.start)
                elif pipeline is not None:
                    GLib.idle_add(pipeline.set_state, Gst.State.PLAYING)
            # Keep the agent's 8-second HTTP write timeout and phone's
            # 7-second request timeout below their limits. Permission dialogs
            # can remain open; the user can retry after approving them.
            deadline = time.monotonic() + 4.5
            while time.monotonic() < deadline:
                with self.lock:
                    frame = self.frame
                    error = self.error
                    running = self.launching
                if frame and time.monotonic() - frame[3] < 2:
                    width, height, jpeg, _at = frame
                    client.sendall(struct.pack(">III", width, height, len(jpeg)) + jpeg)
                    return
                if error and not running and pipeline is None:
                    break
                time.sleep(0.08)
            message = (error or "Approve screen sharing on Ubuntu, then tap Refresh or reopen Live.").encode()[:240]
            client.sendall(struct.pack(">III", 0, 0, len(message)) + message)
        except (ConnectionError, OSError, TimeoutError):
            pass
        finally:
            client.close()

    def bind_socket(self):
        # Bind on the main thread so a duplicate XDG/autostart invocation
        # cannot leave behind a half-running process with no usable socket.
        if not RUNTIME.is_dir() or RUNTIME.is_symlink():
            raise RuntimeError("No private logged-in desktop runtime directory")
        if SOCKET.exists() or SOCKET.is_symlink():
            old = SOCKET.lstat()
            if not stat.S_ISSOCK(old.st_mode) or old.st_uid != os.getuid():
                raise RuntimeError("Refusing to overwrite unexpected screen socket")
            with socket.socket(socket.AF_UNIX) as probe:
                probe.settimeout(0.2)
                try:
                    probe.connect(str(SOCKET))
                except (ConnectionRefusedError, FileNotFoundError):
                    SOCKET.unlink(missing_ok=True)
                else:
                    # XDG autostart and systemd --user may both invoke us.
                    # Exit normally rather than retrying or replacing a
                    # running process.
                    sys.exit(0)
        os.umask(0o077)
        server = socket.socket(socket.AF_UNIX)
        try:
            server.bind(str(SOCKET))
            SOCKET.chmod(0o600)
            server.listen(8)
            return server
        except Exception:
            server.close()
            raise

    def server(self, listener):
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=self.respond,
                             args=(client,), daemon=True).start()


def main():
    Gst.init(None)
    service = ScreenService()
    listener = service.bind_socket()
    threading.Thread(target=service.server, args=(listener,), daemon=True).start()
    GLib.timeout_add_seconds(3, service.check_idle)
    signal.signal(signal.SIGTERM, lambda *_: service.mainloop.quit())
    signal.signal(signal.SIGINT, lambda *_: service.mainloop.quit())
    try:
        service.mainloop.run()
    finally:
        listener.close()
        service.close_stream()
        if SOCKET.exists() and not SOCKET.is_symlink():
            SOCKET.unlink()


if __name__ == "__main__":
    main()
