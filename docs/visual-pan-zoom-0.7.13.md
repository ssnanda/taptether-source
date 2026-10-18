# TapTether 0.7.13+76 — focusable Live and Snapshot

## Phone gestures (portrait and landscape)

- Pinch two fingers to zoom into the desktop preview, from 1× to 4×.
  The content under the fingers stays in place rather than jumping toward
  the display center.
- While zoomed, drag one finger to pan across the screen. Two-finger
  movement can pan and pinch simultaneously, without exposing gray areas
  beyond the captured desktop edges.
- One-finger taps still click the correct computer coordinate after
  zoom/pan. A long press still right-clicks.
- At normal 1× zoom, one-finger drag still moves the remote mouse and
  two-finger vertical drag still scrolls the desktop.
- Zoom controls are available over Snapshot and Live in portrait and
  immersive landscape. Fit-to-screen resets zoom and pan. The view does
  not jump back to 1× with each new Live frame or 15s Snapshot refresh.
- The viewer uses medium-quality texture filtering instead of low-quality
  filtering to avoid visibly jagged intermediate magnification.
- This is an in-memory local view; no captures are stored.

## Local connection performance (optional)

While Live runs, a compact overlay shows the current screenshot
dimensions, received **JPEG bitrate (Mbps)** and measured **frames/s**.
The stream figures come from actual compressed frames delivered to the phone,
not inferred from the selected Wi-Fi band or the internet provider.

Tap the overlay to open Local connection information. **Test LAN speed**
performs three short HTTPS API round-trip checks followed by one bounded
4-MiB test download of synthetic bytes, only from the currently connected,
TLS-certificate-pinned and authenticated desktop agent. This is initiated
solely by the user; the app never performs a speed test automatically,
uploads images or scans the Wi-Fi subnet. Unpaired clients, non-LAN
addresses, plaintext HTTP and oversized benchmarks are rejected at the
agent. Older agents that lack the endpoint display an update message.

The displayed LAN download speed measures real encrypted application
throughput from computer to phone at that moment, **not** the negotiated
Wi-Fi PHY bitrate, upload bandwidth, disk speed or your ISP speed.
Latency is measured as median small authenticated HTTPS request round trip,
not raw ICMP ping. Results can inform a later resolution upgrade but do
not guarantee 1080p/4K capture; encoding/decoding efficiency and hardware
matter too.

## Actual resolution / the protected Mac Screen Core

The current authenticated macOS Screen Core v1, Ubuntu capture helper and
Windows agent all deliver at most **1280×720** screen pixels. Client-side
interpolation and a 4× view **cannot recover high-resolution detail absent
from the source**, no matter how sharp it appears.

True high-detail zoom requires a separate local, authenticated
native-resolution or cropped-region capture mode and matching bounded
transport. In particular, macOS needs a deliberate **Screen Core version
change**; the existing signed Screen Core and its Screen Recording consent
must not be replaced silently. This release does not touch
`SCREEN_CORE_VERSION`, `agent/cmd/taptether-screen-core/`,
`agent/internal/screencap/capture_darwin.go`, signing, or pairing keys.
A protected-core upgrade must have explicit approval, version notes,
and careful macOS permission testing first.

The app remains useful for zooming and panning on older agents, with no
re-pairing. This is a full mobile app release because the UI is updated.
