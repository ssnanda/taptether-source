# TapTether 0.7.6 — Ubuntu Screen Helper tray controls

This release changes **only** the Ubuntu desktop agent and its tray menu
implementation, plus release metadata/documentation. Flutter iPhone and
Android app source code is unchanged. The normal unified release workflow may
still package unchanged app binaries; **no phone app update is needed** to use
the new Ubuntu tray menu.

The existing five top-level tray entries remain unchanged.

### Settings → Screen Helper

- **Status: Running / Stopped** — updates along with the existing tray status.
- **Start Screen Helper / Stop Screen Helper** — starts the logged-in desktop
  capture companion or gracefully stops it through a same-owner private Unix
  socket. The login session, not a privileged system service, owns the helper.
- **Restart Screen Helper** — recover Wayland/PipeWire/X11 capture without
  restarting the whole TapTether background agent, losing pairing, or changing
  trusted credentials. If an older running helper doesn't understand the
  graceful stop request, re-login once after upgrading.
- **Diagnostics…** — displays the agent's existing screen-status report with
  Ubuntu package, dependencies, login session, socket and service status.

The tray launches the capture helper using the logged-in user's own desktop
environment. It never invokes sudo to start screen capture. The screen portal
approval occurs only upon a phone Snapshot/Live request, not by opening the
tray or checking status. Frames stay in memory. The existing MJPEG transport
remains.

Updating from an older Ubuntu tray may require signing out and back into
Ubuntu once for the newly installed tray script to load. Future updates made
through this new tray version refresh its menu after the update completes.

Existing macOS Input Core and Screen Core are not changed or re-signed.
