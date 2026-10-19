# TapTether 0.7.18+81 — truthful My Devices connection state

- Previously an OFFLINE saved device still had an enabled tap handler.
  It initiated a multi-second authenticated network call, overriding OFFLINE
  with CONNECTING and often leaving a raw `SocketException` in the footer.
- One-tap remote access now requires a successful, TLS-pinned authenticated
  saved-host heartbeat. ONLINE is tappable; CHECKING and OFFLINE are inert.
  The explicit Refresh button reruns the saved-host heartbeat. There is
  no unbounded retry, local network scan, or implicit pairing.
- A concurrent background heartbeat cannot mark a foreground-connecting
  saved device offline during an already-authorized connection attempt.
  If the foreground connection fails, that saved device is marked offline
  and a concise check-the-agent/refresh notice replaces raw exception data.
- If the dashboard has saved computers and zero responding agents, it
  displays guidance to check Wi-Fi, the TapTether Agent service and Refresh.
  It does not claim the computer is powered off based solely on a failed
  probe: OFFLINE means **not authenticated/reachable by TapTether**.
- The redundant `Not connected` / `Select a saved device` footer is removed
  for the normal dashboard, where status is already shown for each device.
  Pairing/Discover feedback stays available while those tools are open.
- No changes to secure saved pairings, SSH keys, phone identity, Input Core,
  Screen Core, desktop agents, or permissions.
