# TapTether Ubuntu 0.7.5 screen availability repair

The 0.7.4 release published Ubuntu capture code, but an agent-only update did
not reliably install or start the screen helper. The phone also hid Snapshot
and Live when the graphical helper wasn't running when /api/info was called.

## 0.7.5 repairs

- Both user-initiated and system-managed Ubuntu updates install graphical
  user service + XDG autostart fallback and desktop dependencies.
- The desktop screen helper starts in an active graphical session where
  supported, rather than waiting unconditionally for a logout/re-login.
- The mobile app's existing 0.7 UI now sees the Ubuntu screen-capture
  *capability* when the supporting package is installed, even if the helper is
  temporarily unavailable. Attempting Snapshot or Live shows the underlying
  permission/session error instead of disabled menu choices.
- Duplicate GNOME/systemd helper startup exits safely rather than creating
  a second invisible process.
- First screen request returns an actionable Wayland permission hint quickly,
  within existing phone and agent request timeouts. The user approves the
  native Ubuntu consent prompt, then refreshes/reopens Live.
- Existing Ubuntu keyboard, pointer, media, pairing and restricted uinput
  remain unchanged. **Input Core and Screen Core on macOS are unchanged.**
  The MJPEG transport stays in place.

## Status diagnosis

From the Ubuntu desktop owner account, use:
- `~/.local/bin/taptetherctl screen-status` (latest installed controller)
- If needed, `~/.local/bin/taptetherctl screen-setup` once from the desktop.
- Reconnect to the computer in TapTether on the iPhone after an update.
- On GNOME Wayland, first Snapshot/Live use requires desktop screen-sharing
  approval; no unattended ScreenCast permission bypass is attempted.

This repair is built and statically validated by CI, but actual portal
approval, PipeWire/GStreamer output and pointer coordinates still require
a physical Ubuntu desktop test before declaring complete feature parity.
