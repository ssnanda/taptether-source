#!/usr/bin/python3
"""TapTether desktop menu. UI only; the input agent remains a systemd service.

Starts silently in the tray. No splash or confirmation popups.
Never reads or displays pairing secrets.
"""
import argparse
import fcntl
import signal
import os
import socket
import threading
import time
from pathlib import Path
import subprocess
import sys
import re
from urllib.parse import urlencode

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib, Gdk, GdkPixbuf
except (ImportError, ValueError) as exc:
    raise SystemExit("TapTether tray needs python3-gi and gir1.2-gtk-3.0: " + str(exc))

Indicator = None
for module_name in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(module_name, "0.1")
        Indicator = getattr(__import__("gi.repository", fromlist=[module_name]), module_name)
        break
    except (ImportError, ValueError):
        pass

CTL = Path.home() / ".local" / "bin" / "taptetherctl"
ICON = Path.home() / ".local" / "share" / "icons" / "hicolor" / "512x512" / "apps" / "taptether.png"
SHUTDOWN_DISABLED = Path.home() / ".config" / "taptether" / "remote-shutdown-disabled"
SCREEN_HELPER = Path("/usr/share/taptether/taptether_screen.py")
SCREEN_SOCKET = Path("/run/user") / str(os.getuid()) / "taptether-screen.sock"
SCREEN_DISABLED = Path.home() / ".config" / "taptether" / "screen-sharing-disabled"


def screen_sharing_allowed():
    try:
        SCREEN_DISABLED.lstat()
        return False
    except FileNotFoundError:
        return True
    except OSError:
        return False


def change_screen_sharing_policy(allowed):
    """Store the desktop owner's choice; cannot be changed from the phone."""
    if allowed:
        SCREEN_DISABLED.unlink(missing_ok=True)
    else:
        SCREEN_DISABLED.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            fd = os.open(str(SCREEN_DISABLED),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600)
            os.close(fd)
        except FileExistsError:
            pass
        SCREEN_DISABLED.chmod(0o600)
        # Stop any active portal immediately. The agent also checks each
        # authenticated snapshot/live request and ongoing stream frame.
        screen_request(b"D")




def screen_request(command):
    """Private, owner-only Unix socket; never starts capture on status probe."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(0.4)
            connection.connect(str(SCREEN_SOCKET))
            connection.sendall(command)
            return connection.recv(1) == b"Y"
    except (OSError, TimeoutError):
        return False


def screen_running():
    # A bare socket connect also recognizes previously installed helpers
    # which predate the status opcode. It does not trigger capture/consent.
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(0.25)
            connection.connect(str(SCREEN_SOCKET))
            return True
    except (OSError, TimeoutError):
        return False


def start_screen_helper():
    if screen_running():
        return "Screen Helper is already running."
    if not SCREEN_HELPER.is_file():
        raise RuntimeError("Screen Helper is not installed. Run Install / Repair agent.")
    # Launch directly from the tray (GNOME/X11 GUI session), preserving its
    # Wayland DISPLAY and user D-Bus environment. No root or sudo involved.
    cache = Path.home() / ".cache" / "taptether"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    logfile = cache / "screen-helper.log"
    with logfile.open("wb") as output:
        logfile.chmod(0o600)
        subprocess.Popen(["/usr/bin/python3", str(SCREEN_HELPER)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=output, start_new_session=True, close_fds=True)
    for _ in range(30):
        if screen_running():
            return "Screen Helper started. Screen sharing is requested only when your phone opens Snapshot or Live."
        time.sleep(0.1)
    raise RuntimeError(
        "Screen Helper did not start. Open Screen Helper → Diagnostics to check "
        "dependencies and the graphical session. See ~/.cache/taptether/screen-helper.log."
    )


def stop_screen_helper():
    if not screen_running():
        return "Screen Helper is already stopped."
    if not screen_request(b"Q"):
        raise RuntimeError("Could not stop Screen Helper. Check its diagnostics.")
    for _ in range(30):
        if not screen_running():
            return "Screen Helper stopped. Snapshot and Live are unavailable until restarted."
        time.sleep(0.1)
    raise RuntimeError("Screen Helper did not stop. Check its diagnostics.")


def manage_screen_helper(action, update_menu=None):
    """Run control off the GTK UI thread; keep existing 5-item tray layout."""
    if update_menu is not None:
        update_menu.set_sensitive(False)

    def finished(ok, detail):
        if update_menu is not None:
            update_menu.set_sensitive(True)
        message("Ubuntu Screen Helper", detail, error=not ok)
        return False

    def worker():
        try:
            if action == "start":
                detail = start_screen_helper()
            elif action == "stop":
                detail = stop_screen_helper()
            elif action == "restart":
                stop_screen_helper()
                detail = start_screen_helper()
            elif action == "status":
                proc = subprocess.run(
                    [str(CTL), "screen-status"], capture_output=True,
                    text=True, timeout=12, check=False)
                detail = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
                if proc.returncode != 0:
                    raise RuntimeError(detail or "Screen Helper diagnostics failed.")
            else:
                raise RuntimeError("Unsupported Screen Helper action")
            GLib.idle_add(finished, True, detail[:2000])
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            GLib.idle_add(finished, False, str(exc)[:1800])

    threading.Thread(target=worker, daemon=True).start()


def agent_version():
    try:
        return subprocess.check_output(
            ["/usr/local/bin/taptether-agent", "--version"],
            text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def running():
    return subprocess.run(["systemctl", "is-active", "--quiet", "taptether-agent.service"],
                          timeout=3, check=False).returncode == 0


def message(title, body, error=False):
    # Diagnostics only. Do not display blocking desktop popups.
    print("TapTether " + title + ": " + body[:300], file=sys.stderr)


def show_splash(version):
    # Legacy launcher --splash is intentionally a no-op.
    return False


def run_command(args, title):
    try:
        proc = subprocess.run([str(CTL), *args], capture_output=True, text=True, timeout=30)
        detail = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
        if proc.returncode:
            message(title, detail[:1600] or "Command failed.", error=True)
        else:
            message(title, detail[:1600] or "Operation completed.")
    except (OSError, subprocess.SubprocessError) as exc:
        message(title, str(exc), error=True)


def service_control(action):
    """Ask polkit to control only the named TapTether system service."""
    try:
        result = subprocess.run(
            ["pkexec", "/usr/bin/systemctl", action, "taptether-agent.service"],
            capture_output=True, text=True, timeout=60, check=False)
        if result.returncode:
            message("Service control", "Authorization was declined or unavailable.",
                    error=True)
            return False
        return True
    except (OSError, subprocess.SubprocessError):
        message("Service control", "Could not change TapTether service status.",
                error=True)
        return False


def update_from_tray(item):
    """Run the fixed, privileged update service after explicit confirmation."""
    if not Path("/etc/systemd/system/taptether-update.service").is_file():
        message("Update service unavailable",
                "This computer needs the current TapTether installer once "
                "before tray updates are supported.", error=True)
        return
    item.set_sensitive(False)
    item.set_label("Updating…")

    def finished(ok, details):
        item.set_sensitive(True)
        item.set_label("Check for Updates…")
        if not ok:
            message("Update needs attention", details, error=True)
        if ok:
            # The installed tray script was updated in place. Relaunch this
            # same process so new menu actions appear without logging out.
            try:
                os.execv("/usr/bin/python3",
                         ["/usr/bin/python3", str(Path(__file__).resolve())])
            except OSError:
                message("Tray refresh", "Updated menu will appear at next login.")
        return False

    def worker():
        try:
            # The owner-installed polkit rule authorizes only this named unit.
            cmd = ["systemctl", "start", "--no-block", "taptether-update.service"]
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=25, check=False)
            if result.returncode != 0:
                # A graphical UAC-like prompt, still scoped to the fixed unit.
                result = subprocess.run(["pkexec", "/usr/bin/systemctl",
                    "start", "--no-block", "taptether-update.service"],
                    capture_output=True, text=True, timeout=75, check=False)
            if result.returncode != 0:
                raise RuntimeError("Authorization declined or update request failed.")
            for _ in range(150):
                time.sleep(2)
                state = subprocess.run(["systemctl", "show",
                    "taptether-update.service", "--property=ActiveState",
                    "--property=Result", "--property=ExecMainStatus"],
                    capture_output=True, text=True, timeout=6, check=False)
                if state.returncode != 0:
                    continue
                data = dict(line.split("=", 1) for line in state.stdout.splitlines()
                            if "=" in line)
                if data.get("ActiveState") in ("inactive", "failed"):
                    passed = data.get("ActiveState") == "inactive" and (
                        data.get("Result") == "success") and (
                        data.get("ExecMainStatus") in ("", "0", None))
                    details = ("Installed agent: " + agent_version() +
                               ". Reconnect your phone if needed.") if passed else (
                               "The update service reported an error. "
                               "The previous agent remains installed.")
                    GLib.idle_add(finished, passed, details)
                    return
            raise RuntimeError("The update is taking longer than expected.")
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            GLib.idle_add(finished, False, str(error))

    threading.Thread(target=worker, daemon=True).start()

def show_about_agent(_item):
    dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.INFO,
                               buttons=Gtk.ButtonsType.CLOSE,
                               text="TapTether Agent")
    dialog.format_secondary_text(
        "Version: " + agent_version() + "\\n"
        "Platform: Ubuntu / Linux\\n"
        "Privacy: LAN-only. No accounts, analytics, or telemetry.\\n"
        "Control port: 48321\\n"
        "Service: " + ("Running" if running() else "Stopped"))
    dialog.run()
    dialog.destroy()


def uninstall_from_tray(_item):
    uninstaller = Path.home() / ".local/bin/taptether-uninstall"
    if not uninstaller.is_file():
        message("Uninstall", "Uninstaller is missing. Install or repair the agent first.", error=True)
        return
    dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.WARNING,
                               buttons=Gtk.ButtonsType.NONE,
                               text="Uninstall TapTether from Ubuntu?")
    dialog.format_secondary_text(
        "This removes TapTether services, screen helper and tray.\\n"
        "Keep Pairings preserves phone authorizations and certificates for reinstall.\\n"
        "Erase Everything also removes local TapTether pairing keys and settings.")
    dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dialog.add_button("Keep Pairings", 1)
    dialog.add_button("Erase Everything", 2)
    choice = dialog.run()
    dialog.destroy()
    if choice not in (1, 2):
        return
    if choice == 2:
        confirm = Gtk.MessageDialog(message_type=Gtk.MessageType.WARNING,
                                    buttons=Gtk.ButtonsType.OK_CANCEL,
                                    text="Erase all TapTether pairing data?")
        confirm.format_secondary_text("The phone must pair again. This cannot be undone.")
        choice2 = confirm.run()
        confirm.destroy()
        if choice2 != Gtk.ResponseType.OK:
            return
    mode = "--erase-pairing" if choice == 2 else "--keep-pairing"
    def worker():
        try:
            # Launch an independent process; uninstall will remove the tray
            # itself only after administrator approval.
            subprocess.Popen(["/bin/bash", str(uninstaller), mode],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            GLib.idle_add(message, "Uninstall", "Could not start the uninstaller.", True)
    threading.Thread(target=worker, daemon=True).start()


def add_menu_item(menu, text, callback):
    item = Gtk.MenuItem(label=text)
    item.connect("activate", callback)
    menu.append(item)
    return item


def pair_device(_item):
    """Reveal local pairing credentials only after a direct tray click."""
    try:
        result = subprocess.run([str(CTL), "pairing"], capture_output=True,
                                text=True, timeout=8, check=False)
    except (OSError, subprocess.SubprocessError):
        message("Pair Device", "Unable to read local pairing details.", error=True)
        return
    if result.returncode or not result.stdout.strip():
        message("Pair Device", "Start TapTether and finish setup before pairing.",
                error=True)
        return
    dialog = Gtk.Dialog(title="Private TapTether pairing details",
                        flags=Gtk.DialogFlags.MODAL)
    dialog.add_button("Close", Gtk.ResponseType.CLOSE)
    heading = Gtk.Label(label="Scan the QR using TapTether → Scan QR. Keep this code private.")
    heading.set_xalign(0)
    dialog.get_content_area().pack_start(heading, False, False, 8)
    # Pick a private LAN IP from the agent output. Users with multiple interfaces
    # may choose another address rather than pairing the wrong VPN subnet.
    raw = result.stdout
    ips = []
    for value in re.findall(r'(?<![0-9.])(?:10|192|172)\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(?![0-9.])', raw):
        octets = [int(x) for x in value.split(".")]
        if all(0 <= x <= 255 for x in octets) and (
                octets[0] == 10 or
                (octets[0] == 192 and octets[1] == 168) or
                (octets[0] == 172 and 16 <= octets[1] <= 31)):
            if value not in ips:
                ips.append(value)
    token_match = re.search(r'^Pairing token:\\s*(\\S+)', raw, re.M)
    pin_match = re.search(r'^TLS certificate SHA-256 fingerprint:\\s*([0-9A-Fa-f]{64})', raw, re.M)
    qrbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
    dialog.get_content_area().pack_start(qrbox, False, False, 5)
    if ips and token_match and pin_match:
        ip_choice = Gtk.ComboBoxText()
        for ip in ips:
            ip_choice.append_text(ip)
        ip_choice.set_active(0)
        qrbox.pack_start(ip_choice, False, False, 2)
        qr_image = Gtk.Image()
        qrbox.pack_start(qr_image, False, False, 2)
        qr_hint = Gtk.Label(label="")
        qrbox.pack_start(qr_hint, False, False, 2)

        def render_code(_widget=None):
            uri = "taptether://pair?" + urlencode({
                "v": "1", "host": ip_choice.get_active_text(),
                "token": token_match.group(1),
                "fingerprint": pin_match.group(1).upper()})
            try:
                proc = subprocess.run(["qrencode", "-t", "PNG", "-s", "8",
                                       "-m", "2", "-o", "-"],
                                      input=uri.encode(), stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, timeout=5, check=True)
                loader = GdkPixbuf.PixbufLoader.new_with_type("png")
                loader.write(proc.stdout)
                loader.close()
                qr_image.set_from_pixbuf(loader.get_pixbuf())
                qr_hint.set_text("QR for " + ip_choice.get_active_text())
            except (OSError, subprocess.SubprocessError, GLib.Error):
                qr_hint.set_text("QR unavailable. Install qrencode, or use the text below.")
        ip_choice.connect("changed", render_code)
        render_code()
    else:
        qrbox.pack_start(Gtk.Label(label="Pairing QR unavailable; use the text below."), False, False, 2)
    scroller = Gtk.ScrolledWindow()
    scroller.set_size_request(580, 145)
    display = Gtk.TextView()
    display.set_editable(False)
    display.set_cursor_visible(True)
    display.set_monospace(True)
    display.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
    display.get_buffer().set_text(result.stdout.strip())
    scroller.add(display)
    dialog.get_content_area().pack_start(scroller, True, True, 8)
    dialog.show_all()
    dialog.run()
    dialog.destroy()


def menu(version):
    m = Gtk.Menu()
    version_item = add_menu_item(m, "TapTether Agent v" + version,
                                  lambda _: None)
    version_item.set_sensitive(False)
    status = add_menu_item(m, "", lambda _: None)
    status.set_sensitive(False)
    m.append(Gtk.SeparatorMenuItem())

    def toggle(item):
        action = "stop" if running() else "start"
        if service_control(action):
            refresh()

    start_stop = add_menu_item(m, "Start TapTether", toggle)
    add_menu_item(m, "Pair Device", pair_device)
    add_menu_item(m, "Check for Updates…", update_from_tray)

    settings_item = Gtk.MenuItem(label="Settings")
    settings = Gtk.Menu()
    add_menu_item(settings, "Restart agent",
                  lambda _: (service_control("restart"), refresh()))
    add_menu_item(settings, "Agent status",
                  lambda _: message("TapTether Agent",
                                    "Version: " + agent_version() + "\\nStatus: " +
                                    ("Running" if running() else "Stopped")))
    add_menu_item(settings, "Install / Repair agent…",
                  lambda _: message("Install / Repair TapTether",
                                    "Run ~/.local/bin/taptetherctl install in a trusted terminal. "
                                    "Administrator authorization may be required."))

    # Mirror macOS privacy-helper visibility without adding a sixth top-level
    # item. These controls manage only the owner's desktop screen source.
    screen_item = Gtk.MenuItem(label="Screen Helper")
    screen_menu = Gtk.Menu()
    screen_state = Gtk.MenuItem(label="Status: Checking…")
    screen_state.set_sensitive(False)
    screen_menu.append(screen_state)
    sharing = Gtk.CheckMenuItem(label="Allow screen sharing (Snapshot / Live)")
    sharing.set_active(screen_sharing_allowed())

    def toggle_sharing(item):
        try:
            change_screen_sharing_policy(item.get_active())
            refresh()
        except OSError:
            item.handler_block_by_func(toggle_sharing)
            item.set_active(screen_sharing_allowed())
            item.handler_unblock_by_func(toggle_sharing)
            message("Screen sharing",
                    "Could not change local sharing permission.",
                    error=True)

    sharing.connect("toggled", toggle_sharing)
    screen_menu.append(sharing)
    screen_menu.append(Gtk.SeparatorMenuItem())
    screen_toggle = add_menu_item(screen_menu, "Start Screen Helper",
                                  lambda item: manage_screen_helper(
                                      "stop" if screen_running() else "start", item))
    add_menu_item(screen_menu, "Restart Screen Helper",
                  lambda item: manage_screen_helper("restart", item))
    add_menu_item(screen_menu, "Diagnostics…",
                  lambda item: manage_screen_helper("status", item))
    screen_item.set_submenu(screen_menu)
    settings.append(screen_item)
    shutdown = Gtk.CheckMenuItem(label="Allow remote shutdown")
    shutdown.set_active(not SHUTDOWN_DISABLED.exists())

    def change_shutdown(item):
        try:
            if item.get_active():
                SHUTDOWN_DISABLED.unlink(missing_ok=True)
            else:
                SHUTDOWN_DISABLED.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                SHUTDOWN_DISABLED.touch(mode=0o600, exist_ok=True)
                SHUTDOWN_DISABLED.chmod(0o600)
        except OSError:
            item.handler_block_by_func(change_shutdown)
            item.set_active(not item.get_active())
            item.handler_unblock_by_func(change_shutdown)
            message("Remote shutdown", "Could not change local shutdown preference.",
                    error=True)

    shutdown.connect("toggled", change_shutdown)
    settings.append(shutdown)
    add_menu_item(settings, "About TapTether Agent…", show_about_agent)
    settings.append(Gtk.SeparatorMenuItem())
    add_menu_item(settings, "Uninstall TapTether…", uninstall_from_tray)
    settings_item.set_submenu(settings)
    m.append(settings_item)
    m.append(Gtk.SeparatorMenuItem())

    def quit_taptether(_item):
        # Never exit the tray while leaving a managed agent running.
        if service_control("stop"):
            Gtk.main_quit()

    add_menu_item(m, "Quit TapTether", quit_taptether)

    previous_lan_ips = None
    ip_changed_until = 0.0

    def current_lan_ips():
        try:
            result = subprocess.run(
                ["ip", "-o", "-4", "addr", "show", "scope", "global"],
                capture_output=True, text=True, timeout=2, check=False)
            return tuple(sorted(line.split(" inet ", 1)[1].split("/", 1)[0]
                for line in result.stdout.splitlines() if " inet " in line))
        except (OSError, subprocess.SubprocessError, IndexError):
            return ()

    def refresh():
        nonlocal previous_lan_ips, ip_changed_until
        ips = current_lan_ips()
        if previous_lan_ips is not None and ips and ips != previous_lan_ips:
            ip_changed_until = time.monotonic() + 3600
        if ips:
            previous_lan_ips = ips
        version_item.set_label("TapTether Agent v" + agent_version())
        active = running()
        status.set_label("Status: " + ("Running" if active else "Stopped") +
                         (" 🔴 IP changed" if time.monotonic() < ip_changed_until else ""))
        start_stop.set_label("Stop TapTether" if active else "Start TapTether")
        helper_active = screen_running()
        allowed = screen_sharing_allowed()
        screen_state.set_label("Screen sharing: " + ("Allowed" if allowed else "Blocked"))
        sharing.handler_block_by_func(toggle_sharing)
        sharing.set_active(allowed)
        sharing.handler_unblock_by_func(toggle_sharing)
        screen_toggle.set_label("Stop Screen Helper" if helper_active else "Start Screen Helper")
        return True

    refresh()
    GLib.timeout_add_seconds(10, refresh)
    m.show_all()
    return m


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--splash", action="store_true")
    args = parser.parse_args()
    version = agent_version()
    # The autostart tray is a singleton. Opening from the dock sends it a
    # splash request rather than creating another status indicator.
    lockpath = Path.home() / ".cache" / "taptether" / "tray.lock"
    lockpath.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lockfile = lockpath.open("a+", encoding="ascii")
    try:
        fcntl.flock(lockfile.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    lockfile.seek(0)
    lockfile.truncate()
    lockfile.write(str(os.getpid()))
    lockfile.flush()
    # Clicking the app launcher just focuses the already-running tray.

    if Indicator is not None:
        indicator = Indicator.Indicator.new(
            "taptether", "taptether", Indicator.IndicatorCategory.APPLICATION_STATUS)
        indicator.set_icon_theme_path(str(ICON.parent))
        if ICON.is_file():
            # The AppIndicator icon must point to our installed asset. GNOME
            # Wayland cannot reliably show GTK StatusIcon notification icons.
            indicator.set_icon_full(str(ICON), "TapTether Agent")
        else:
            indicator.set_icon_full("input-mouse", "TapTether Agent")
        indicator.set_status(Indicator.IndicatorStatus.ACTIVE)
        indicator.set_menu(menu(version))
    else:
        # GTK StatusIcon fallback is X11-only. There must never be a
        # permanently visible GTK window in the dock or task switcher.
        if os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland":
            print("TapTether tray requires AppIndicator support on Wayland. "
                  "Install the Ubuntu AppIndicator extension and "
                  "gir1.2-ayatanaappindicator3-0.1.", file=sys.stderr)
            return
        icon = Gtk.StatusIcon()
        if ICON.exists():
            icon.set_from_file(str(ICON))
        else:
            icon.set_from_icon_name("input-mouse")
        icon.set_tooltip_text("TapTether Agent v" + version)
        popup = menu(version)
        icon.connect("popup-menu", lambda tray, button, activate: popup.popup(
            None, None, Gtk.StatusIcon.position_menu, tray, button, activate))

    Gtk.main()


if __name__ == "__main__":
    main()
