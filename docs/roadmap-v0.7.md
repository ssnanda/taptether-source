# TapTether 0.7 — Visual & Media Remote

Status: in-development implementation in draft PR #40. macOS ScreenCaptureKit capture, Snapshot refresh/taps, in-app Live MJPEG preview and authenticated default-browser Media are coded but require CI and hands-on permission, screen-coordinate, latency and device validation. Do not merge or publish 0.7 yet.

## Scope and interface
- Existing computer Remote stays primary and preserves trackpad and keyboard.
- Within Remote, a three-way control *Trackpad / Snapshot / Live* replaces the trackpad surface. Snapshot and Live become selectable only after the paired agent reports actual screen-capture capability. Unsupported agents remain in Trackpad.
- Snapshot: opt-in capture only while viewing the remote; refresh on entering mode, every **15 seconds**, manual Refresh now, and after user clicks; immediately stop on hide, disconnect or background. Keep original screenshot in memory only and enforce small bounded sizes.
- Live: opt-in local-only authenticated streaming of the computer's screen into the **same surface**, not a different app; optimize for latency, start at adaptive **720p / 30 FPS**, first one monitor; include pointer mapping, zoom, right click and scroll.
- Touch on image is translated from rendered screenshot coordinates to the chosen monitor's full pixel frame. Gestures use transform after zoom/letterboxing; no guesswork. Retain normal remote keyboard.
- Add third top-level connected tab *Media* alongside *Remote* and *Presentation*; never mix Netflix/YouTube shortcuts into slide navigation. Within Media switch **YouTube/Netflix**, focused search field, play/pause, seek, fullscreen, volume ± and mute. Media playback uses authenticated keyboard/audio shortcuts; browsing uses an agent-side strict YouTube/Netflix allowlist to open the destination with the desktop's default browser. Media also keeps a compact trackpad and text input. Do not claim to control smart TV apps.
- Presentation mode remains intact; slide previews/speaker notes integration can reuse future screen capture.

## Capture engineering
1. **Implemented provisionally on macOS:** ScreenCaptureKit (SCScreenshotManager, macOS 14+) primary-display capture and Screen Recording TCC consent, entirely in memory. CoreGraphics' old CGDisplayCreateImage is unavailable in recent SDKs, so the native agent uses a ScreenCaptureKit Objective-C bridge. Verify real on-device capture, scale/orientation, permission flow and CPU costs. Mac systems below 14 have no visual capture support. **Pending:** Windows Graphics Capture and Linux PipeWire/XDG Desktop Portal on Wayland (X11 fallback). Screen Recording permission is distinct from Accessibility.
2. Agent endpoints require existing pinned TLS, authenticated phone identity/session, RFC1918 LAN, no unauthenticated preview, no third-party relay and no permanent screenshot storage.
3. Snapshot API returns a bounded JPEG/WebP, no-store, rate limited, one capture request at a time; first baseline per host only after success on that host.
4. **Implemented preview:** one-viewer authenticated multipart MJPEG stream, 720p upper bound, 30 FPS target (adaptive lower real FPS based on encoding), with client cancellation on leaving screen/background/disconnect. No WebRTC/H.264 yet; migrate to an efficient hardware H.264 transport and benchmark real latency before release.
5. Expect protected DRM playback (Netflix etc.) to return a black/blank protected video area. Do not attempt bypass. Media controls and page navigation may still work.
6. Network uses existing secure local connection. No cloud streaming, accounts, analytics, recordings, or persistent frames.
7. Cross-platform: macOS first for visual control, then Windows, then Ubuntu Wayland; media keyboard input supported where the existing input backend supports it.

## Development order and release gates
- Phase A (coded): 0.7 feature branch, per-host visual/media preferences, connected **Media** tab, YouTube/Netflix switching, volume and playback shortcuts, secure default-browser launch, regression tests and this roadmap. No release bump.
- Phase B (coded; validation pending): authenticated macOS Snapshot backend, permission request, automatic 15-second/after-input refresh, same trackpad area, relative-to-primary normalized tap mapping, pinch zoom, long-press right-click and two-finger scroll. Verify actual pixels, zoom mapping and permission prompt on Macs, and no capture when inactive.
- Phase C (preview coded; not release-ready): authenticated MJPEG Live preview shares the same surface, pointer mapping, authentication and permissions. Measure real frame rate and latency, implement production H.264/WebRTC if needed, then add Windows and Ubuntu capture after macOS works.
- When stable: merge tested features into main, increment to 0.7.0 with next build number, run existing single gated GitHub workflow, publish IPA/APK + desktop agents, verify release + altstore feed and perform normal personal usage tests.

## Roadmap rescope
Previous roadmap: 0.7 Windows/Raspberry Pi/ARM/direct SSH; 0.8 TVs/entertainment; 0.9 remote desktop; 1.0 stable; 1.1 presentation. Revised 0.7 prioritizes Snapshot, Media, Live while preserving existing OS support. Defer new TV platforms, full remote desktop extras, clipboard and file transfer until after visual control. No Wake-on-LAN. Shutdown stays under existing simple power controls.

## Current validation notes
- The single existing GitHub Actions workflow now runs **validate only** on app/agent pull requests; it does not create releases on draft PRs. Normal publishing remains main VERSION-gated.
- The route observer and lifecycle observer stop requesting/streaming frames when Remote is hidden, another route opens, the device disconnects or the app backgrounds. No local file writes and no remote upload path for screen content.
- Before release verify macOS Intel and Apple Silicon compile, macOS Screen Recording prompts, tap coordinates with letterboxing and scaled displays, Safari/Chrome YouTube and Netflix keyboard shortcuts, codec CPU/network budget, orientation changes and 0.6.12 pairing regression.
