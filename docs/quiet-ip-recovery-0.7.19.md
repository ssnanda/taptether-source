# TapTether 0.7.19+82 — Quiet DHCP recovery & tray UX

- **Instant My Devices:** saved pairings display immediately, without waiting
  for discovery, scanning, or agent network responses. Previously saved IPs are
  checked in parallel using authenticated, certificate-pinned heartbeats.
- **Automatic recovery only when none respond:** in the foreground, one
  two-second UDP broadcast (global + the current Wi-Fi's directed broadcast)
  discovers agents on the current Wi-Fi CIDR. There is **no automatic TCP scan,
  /24 unicast sweep, or search of any other subnet**. Automatic recovery is
  limited to once per 10 minutes; Refresh forces the same lightweight check.
- Only the original saved certificate pin + phone credentials can authorize
  updating a saved address. Untrusted UDP names, platform hints and MAC
  addresses are never considered sufficient proof. No re-pairing is required
  for a verified DHCP move. Full manual Scan IPs remains available for
  networks where Wi-Fi broadcast is disabled.
- Desktop agents check **local interface addresses once a minute** without
  sending any packets. If the IP changed, they send a small public (no token
  or TLS fingerprint) LAN UDP announcement **at most once per hour**. They
  still answer existing on-demand UDP probes immediately. The phone listens
  to unsolicited announcements only while running in the foreground.
  iOS cannot be relied on to receive LAN UDP while the app is suspended.
- macOS/Ubuntu/Windows tray menus show a tiny red IP-change marker for up
  to an hour after detecting a change. These are informational, **not error
  or update prompts**; never open a modal dialog for IP changes.
- Desktop tray opening, reopening, installation, successful updates, and
  ordinary agent status changes are silent: **no splash window or update
  complete pop-up**. Explicit pairing credentials, uninstall confirmation,
  and macOS OS-permission settings remain user-initiated workflows.
- Windows screenshots & keyboard, Ubuntu Wayland/X11 helpers, and protected
  signed macOS Input Core / Screen Core are unchanged.

## Notes
UDP broadcast can be restricted by guest Wi-Fi, enterprise routing,
firewall policy or mobile OS permissions. This fallback cannot discover
agents across routed subnets or when the computer is asleep/off.
Manual discovery and managing saved addresses remain separate tools.
