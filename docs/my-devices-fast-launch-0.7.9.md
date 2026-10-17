# TapTether 0.7.9+72: My Devices is a saved-computer launcher

### Fast saved-device dashboard
- My Devices immediately displays saved entries (both checked and unchecked),
  with **ONLINE**, **CHECKING**, and **OFFLINE** labels. Authenticated online
  entries float to the top without hiding saved offline computers.
- Background status checks contact *only saved IPs* with the persisted TLS
  certificate pin and signed phone identity. The dashboard never initiates
  UDP discovery, Bonjour, TCP subnet probing, or IP range enumeration.
- Existing explicit **Discover** and **Scan IPs** actions still work under
  collapsed **Add / Discover** tools and the navigation menu. DHCP recovery
  remains an explicit discovery action, and new IPs are never trusted based
  on hostname/port alone.
- The full-width heartbeat scanning progress bar and crowded quick-action
  row are removed. Wi-Fi labeling and raw discovery logs stay under the
  collapsed tools rather than cluttering the saved-device list.

### Faster connection
- A tap immediately shows **CONNECTING** on that saved device and blocks
  duplicate connect taps.
- Existing saved pairings reuse a cached local Ed25519 phone identity.
- Modern agents use the authenticated, TLS-pinned agent info request as the
  initial connectivity check rather than doing a redundant ping first.
  Legacy agents retain their ping fallback.
- Verified saved devices enter the remote without waiting for a background
  secure-storage metadata refresh and display layout load.
- Connection time still depends on local Wi-Fi and TLS/authentication; one
  second is the responsiveness goal, not a guaranteed timeout.
- No weaker certificate, pairing, or auth verification is introduced.

### Returning to My Devices
- Portrait remote app bar has a **Back** arrow with “Back to My Devices”
  accessibility label.
- Landscape remote dock has the same Back action.
- The old **Switch computer** and redundant disconnect UI are removed.
  Back closes the active local control session and returns to saved devices.

### Release scope
- Full mobile UI update (IPA/APK), version 0.7.9+72; agents rebuild through
  the existing validated synchronized workflow. Ubuntu 0.7.8+71 agents remain
  compatible. macOS protected Input/Screen Core source is not changed.
