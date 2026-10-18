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
