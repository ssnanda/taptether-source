#!/usr/bin/python3
"""TapTether desktop menu. UI only; the input agent remains a systemd service.

Starts at graphical login without splash; launching it from the dock displays a
brief splash. Never reads or displays pairing secrets.
"""
import argparse
import fcntl
import signal
import os
from pathlib import Path
import subprocess
import sys

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib, Gdk
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
    dialog = Gtk.MessageDialog(
        None, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR if error else Gtk.MessageType.INFO,
        Gtk.ButtonsType.OK, title)
    dialog.format_secondary_text(body)
    dialog.run()
    dialog.destroy()


def show_splash(version):
    window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
    window.set_title("TapTether Agent")
    window.set_default_size(340, 260)
    window.set_resizable(False)
    window.set_position(Gtk.WindowPosition.CENTER)
    window.set_decorated(False)
    window.set_skip_taskbar_hint(True)
    window.set_skip_pager_hint(True)
    window.set_type_hint(Gdk.WindowTypeHint.UTILITY)
    window.set_keep_above(True)
    outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    outer.set_border_width(24)
    if ICON.exists():
        try:
            picture = Gtk.Image.new_from_file(str(ICON))
            picture.set_pixel_size(88)
            # Pixbuf scale rather than Gtk image pixel-size on file-based images.
            from gi.repository import GdkPixbuf
            pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(ICON), 88, 88, True)
            picture.set_from_pixbuf(pix)
            outer.pack_start(picture, False, False, 6)
        except GLib.Error:
            pass
    title = Gtk.Label()
    title.set_markup("<span size='xx-large' weight='bold'>TapTether Agent</span>")
    outer.pack_start(title, False, False, 4)
    outer.pack_start(Gtk.Label(label="Your devices. Your control. Your network."), False, False, 4)
    outer.pack_start(Gtk.Label(label="v" + version), False, False, 4)
    outer.pack_start(Gtk.Label(label="Running in the background" if running()
                               else "Agent is currently stopped"), False, False, 4)
    window.add(outer)
    window.show_all()
    GLib.timeout_add(2200, lambda: (window.destroy(), False)[1])


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


def on_command(item, *args):
    # Running sudo commands in a background menu without a TTY would stall or fail.
    # Use a graphical polkit authorization prompt where supported.
    command = args[0]
    if command == "update":
        run_command(["check-update"], "TapTether update check")
    elif command in ("start", "restart", "stop"):
        try:
            result = subprocess.run(
                ["pkexec", "/usr/bin/systemctl", command, "taptether-agent.service"],
                capture_output=True, text=True, timeout=60, check=False)
            if result.returncode:
                message("Service control", result.stderr.strip()[:1000] or
                        "Authorization was declined or unavailable.", error=True)
        except (OSError, subprocess.SubprocessError) as exc:
            message("Service control", str(exc), error=True)


def add_menu_item(menu, text, callback):
    item = Gtk.MenuItem(label=text)
    item.connect("activate", callback)
    menu.append(item)
    return item


def menu(version):
    m = Gtk.Menu()
    status_item = add_menu_item(m, "TapTether Agent v" + version, lambda _: show_splash(version))
    status_item.set_sensitive(True)
    status = add_menu_item(m, "", lambda _: None)
    status.set_sensitive(False)

    def refresh():
        status.set_label("Status: " + ("Running" if running() else "Stopped"))
        return True

    refresh()
    GLib.timeout_add_seconds(10, refresh)
    m.append(Gtk.SeparatorMenuItem())
    add_menu_item(m, "Show TapTether", lambda _: show_splash(version))
    add_menu_item(m, "Start agent", lambda item: on_command(item, "start"))
    add_menu_item(m, "Restart agent", lambda item: on_command(item, "restart"))
    add_menu_item(m, "Stop agent", lambda item: on_command(item, "stop"))
    add_menu_item(m, "Check for updates", lambda item: on_command(item, "update"))
    m.append(Gtk.SeparatorMenuItem())
    add_menu_item(m, "Pairing instructions", lambda _: message(
        "Pair a phone", "Use a trusted terminal and run:\n"
        "~/.local/bin/taptetherctl pairing-qr\n\n"
        "Pairing tokens are never displayed in this tray menu."))
    add_menu_item(m, "Quit tray (agent stays running)", lambda _: Gtk.main_quit())
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
        if args.splash:
            try:
                lockfile.seek(0)
                os.kill(int(lockfile.read().strip()), signal.SIGUSR1)
            except (ValueError, OSError, ProcessLookupError):
                pass
        return
    lockfile.seek(0)
    lockfile.truncate()
    lockfile.write(str(os.getpid()))
    lockfile.flush()
    signal.signal(signal.SIGUSR1, lambda *_: GLib.idle_add(show_splash, version))

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
        if not Gdk.Display.get_default() or not (
                Gdk.Display.get_default().get_name().startswith(":")):
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

    if args.splash:
        GLib.idle_add(show_splash, version)
    Gtk.main()


if __name__ == "__main__":
    main()
