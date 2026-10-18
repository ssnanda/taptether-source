# TapTether 0.7 — Visual & Media Remote

Status: **0.7.14+77 published**; **0.7.15+78 high-detail and media improvements in development**.
This supersedes the original pre-release draft of this roadmap.

## Delivered phone experience

- One-row Remote / Slides / Media navigation in portrait, and a compact
  auto-hiding dock in immersive landscape.
- Within Remote: Trackpad / Snapshot / Live share the same interactive input
  surface. Touch, drag, zoom, tap, double-click, right-click, scroll and
  keyboard input are available in the supported visual modes.
- Snapshot captures a temporary frame on entry, every 15 seconds, after
  clicks/scrolls, and on manual refresh. No screenshot recording/storage.
- Live uses the existing authenticated local MJPEG 720p preview. The product
  owner explicitly accepted keeping MJPEG for 0.7; hardware H.264/WebRTC
  conversion is not a 0.7 exit criterion.
- Media controls YouTube/Netflix searches via allowed desktop-browser
  destinations, playback, volume and mute. Protected DRM video may appear
  black or blank in a screen preview.
- Slides includes presentation start, next/previous, blank and end, volume
  through the existing connected remote, and optional phone-only PPTX notes.

## OS coverage

| OS | Existing keyboard/trackpad | Snapshot | Live (MJPEG) | Slides/Media |
| --- | --- | --- | --- | --- |
| macOS | Shipped; protected Input Core | Shipped; protected Screen Core | Shipped | Shipped |
| Ubuntu GNOME Wayland / X11 | Shipped using restricted uinput | In 0.7.4 PR; physical testing required | In 0.7.4 PR; physical testing required | Existing Slides; graphical browser route added in 0.7.4 |
| Windows | Shipped; automated builds | Provisional GDI backend | Provisional MJPEG backend | Existing controls |

Windows physical agent testing is **waived by the owner** for this
milestone; automated compile/package checks remain mandatory.
The owner is already testing iPhone and Mac physically.
Ubuntu capture and absolute-pointer behavior require a real Ubuntu desktop
test before being described as fully verified; implementation details and
first-login instructions are in [ubuntu-screen-capture.md](ubuntu-screen-capture.md).

## Security and platform boundaries

- All screen data remain in volatile memory; remote requests use the existing
  paired phone identity, pinned TLS and private LAN enforcement.
- On macOS Input Core and Screen Core remain independently version-pinned,
  with no routine re-signing, replacement or TCC permission resets.
- Ubuntu screen capture runs in the logged-in user's desktop process, and
  uses the XDG Portal ScreenCast / PipeWire consent flow on Wayland or a
  GStreamer X11 source. A private local socket connects it to the existing
  unprivileged background agent; capture pauses when no visual view is active.
- The Ubuntu system service does not bypass operating-system screen consent.
- No accounts, cloud relay, analytics or persistent screen recordings.

## Validation / 0.7 exit criteria

1. CI: Go vet/tests, Flutter analysis/widget tests, all agent cross-compiles,
   Debian and Mac installer verification, and an iOS/Android release build.
2. Owner's physical iPhone/macOS validation of visuals, touch gestures,
   landscape, media and protected-core permission preservation.
3. First Ubuntu Wayland/X11 device validation of screen consent, image
   coordinates, input clicks, presentation shortcuts and media browser.
4. Publish artifacts and AltStore feed via the single GitHub Actions workflow.
   Do not mark new Ubuntu capture as hardware-verified based only on green CI.

## Next roadmap

After visual/media stability: LG webOS local TV remote, then Remote Desktop,
SSH controls and later optional IoT features. File transfer and clipboard
sharing remain outside the visual remote milestone.

## 0.7.15+78 in-progress follow-up (2026-10-18)

- On-demand higher-detail 1920×1080 *full-frame* Snapshot when the
  computer backend supports it. Detail is requested explicitly from the
  Snapshot/Live surface; Live pauses and switches to Snapshot. One 1080p
  frame never implies that the whole live MJPEG feed is 1080p.
- Windows GDI supports high-detail primary display capture. On macOS it
  requires an independently versioned Screen Core 2, never silently
  replacing a user's installed Screen Core 1. See the protected-core notes.
  Ubuntu stays at 720p until a second PipeWire quality path is designed and
  tested against the native-memory crash regression.
- Live remains 720p MJPEG, with bounded 8/15/30 fps requests and
  conservative one-time client downshift/upshift using measured frame rate.
  This does not promise hardware encoding, packet-loss telemetry or 4K.
- Netflix exits video by leaving fullscreen then returning to the signed-in
  browse page in the *same tab*; this does not inspect or click a
  website-specific DOM back arrow. Search requires explicit Search-page
  entry. Profile selection remains assisted through the browser UI.
- Browser URL/profile awareness and a direct profile card-picker are
  **not** claimed: browser websites do not expose these to a generic LAN
  remote. Those would require an opt-in browser extension with separate
  user permission and site-specific maintenance. No credentials are stored.
- Closing a provider closes the focused browser tab after confirmation,
  never the entire browser process, because other unrelated tabs may be open.

0.7 closure still needs physical browser, Ubuntu, macOS Screen Core v2
opt-in and image-quality testing. Windows physical testing is waived.
