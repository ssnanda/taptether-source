# TapTether 0.7.4 — Ubuntu Visual & Media Remote

This implements the same **Remote / Slides / Media** phone navigation as macOS
without any change to the protected macOS Input Core or Screen Core.

## Ubuntu visual control

- Snapshot uses the existing 15-second refresh, manual refresh, and post-click refresh.
- Live uses the current authenticated local MJPEG transport. No H.264/WebRTC migration
  is required for 0.7; actual frame rate depends on the Linux desktop.
- Both modes reuse the interactive trackpad surface, right-click, double-click,
  two-finger scroll, pinch zoom, keyboard input, and portrait/landscape layouts.
- Ubuntu GNOME Wayland: standard XDG Desktop Portal ScreenCast / PipeWire stream;
  Ubuntu X11: GStreamer ximagesrc. A single monitor is selected when sharing.
- Capture frames are kept solely in memory and handed to the existing agent
  through a private same-user Unix socket under /run/user/<uid>. Never persisted.
  Capture pauses when the phone has not requested frames for 35 seconds.
- Ubuntu absolute taps use a separate restricted /dev/uinput tablet-style pointer,
  avoiding X11-only mouse injection. Compositors may differ in how they map the
  pointer with multiple physical monitors; initial release targets a single monitor.
- The agent runs as its existing unprivileged system service. The screen helper
  runs as the desktop user, installed via XDG autostart and available only when
  that user is logged in. A system reboot or SSH-only boot cannot share a screen.
- Wayland will show the desktop's normal screen-sharing consent dialog on first
  use. The portal restoration token (when supported) is saved as a private
  0600 file; only consent metadata, **not pixels or recordings**, is stored.

## Installation and first use

1. Update to the new Ubuntu .deb and run `taptether-setup install` once as
   the non-root desktop owner. This installs optional screen dependencies and
   the graphical-session autostart helper. Existing user-approved agent updates
   also install the new autostart entry.
2. Log out and log back in to Ubuntu's graphical desktop (GNOME Wayland or X11).
   Do not launch the screen helper from a plain SSH shell: it needs the user's
   Wayland/X11 environment and user D-Bus session.
3. Connect in the mobile app. Select Remote → Snapshot or Live. On Wayland,
   approve the operating system's monitor-sharing dialog. If the first request
   times out while approving, retry Snapshot or Live after consent.
4. The existing Slides mode sends keyboard shortcuts to LibreOffice Impress
   (F5 to present), Google Slides in a browser, and compatible .pptx viewers;
   Keynote remains macOS-only. Phone-local .pptx speaker notes are unchanged.
5. Media opens allowlisted YouTube or Netflix links in the logged-in Ubuntu
   user's default browser; playback and volume use the existing virtual input.

## Support and limitations

This is the first Ubuntu visual implementation and **requires a real Ubuntu
desktop validation** (especially GNOME Wayland permission handling and normalized
taps). The successful pipeline is not equivalent to hardware validation.
Ubuntu 22.04/24.04 GNOME and modern X11 are intended; other compositors must
provide a working ScreenCast portal implementation. Linux desktop screenshot
APIs vary, so GNOME portal behavior is not identical to macOS permissions.

If Snapshot/Live is disabled, verify the Ubuntu user is logged in and the
screen helper is running under that user. The installer uses optional packages
`python3-gi`, `python3-pil`, `gir1.2-gstreamer-1.0`,
`gir1.2-gst-plugins-base-1.0`, `gstreamer1.0-plugins-good`,
`gstreamer1.0-pipewire`, and `xdg-desktop-portal`.

The authenticated TCP endpoints still require a trusted paired phone, the
existing pinned TLS certificate, and a private LAN. Do not expose TCP 48321
or the Unix socket over the public internet.
