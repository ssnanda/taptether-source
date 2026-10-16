# TapTether 0.7 — Visual & Media Remote

Status: development foundation. Do not publish as a completed 0.7 release until authenticated capture, screen permissions, UI input mapping, and tests are functional.

## Scope and interface
- Existing computer Remote stays primary and preserves trackpad and keyboard.
- Within Remote, a three-way control *Trackpad / Snapshot / Live* replaces the trackpad surface. Until their transports exist, Snapshot and Live controls are explicitly disabled, never fake data.
- Snapshot: opt-in capture only while viewing the remote; refresh on entering mode, every **15 seconds**, manual Refresh now, and after user clicks; immediately stop on hide, disconnect or background. Keep original screenshot in memory only and enforce small bounded sizes.
- Live: opt-in local-only authenticated streaming of the computer's screen into the **same surface**, not a different app; optimize for latency, start at adaptive **720p / 30 FPS**, first one monitor; include pointer mapping, zoom, right click and scroll.
- Touch on image is translated from rendered screenshot coordinates to the chosen monitor's full pixel frame. Gestures use transform after zoom/letterboxing; no guesswork. Retain normal remote keyboard.
- Add third top-level connected tab *Media* alongside *Remote* and *Presentation*; never mix Netflix/YouTube shortcuts into slide navigation. Within Media switch **YouTube/Netflix**, focused search field, play/pause, seek, fullscreen, volume ± and mute. Current starter uses keyboard shortcuts and opens query URL in the *foreground browser*; do not claim to control smart TV apps.
- Presentation mode remains intact; slide previews/speaker notes integration can reuse future screen capture.

## Capture engineering
1. Platform screen capture: macOS ScreenCaptureKit, Windows Graphics Capture, Linux PipeWire/XDG Desktop Portal on Wayland (X11 fallback). OS permission consent required. Mac Screen Recording permission is distinct from Accessibility permission.
2. Agent endpoints require existing pinned TLS, authenticated phone identity/session, RFC1918 LAN, no unauthenticated preview, no third-party relay and no permanent screenshot storage.
3. Snapshot API returns a bounded JPEG/WebP, no-store, rate limited, one capture request at a time; first baseline per host only after success on that host.
4. Streaming session scoped to an explicit active viewer, requires user opt-in, stops on leaving screen/background/disconnect. Use hardware H.264 where available; WebRTC or comparable low-latency local transport with session-scoped authorization.
5. Expect protected DRM playback (Netflix etc.) to return a black/blank protected video area. Do not attempt bypass. Media controls and page navigation may still work.
6. Network uses existing secure local connection. No cloud streaming, accounts, analytics, recordings, or persistent frames.
7. Cross-platform: macOS first for visual control, then Windows, then Ubuntu Wayland; media keyboard input supported where the existing input backend supports it.

## Development order and release gates
- Phase A (started): 0.7 feature branch, per-host visual/media preferences, connected **Media** tab, YouTube/Netflix switching, volume and playback shortcuts, browser-focused video search, regression tests and this roadmap. No release bump.
- Phase B: authenticated Snapshot backend + permissions + 15-second/after-click refresh, same trackpad area and touch mapping. Verify actual pixels on macOS and no capture when inactive.
- Phase C: Live screen transport and 720p30 adaptive tuning. Reuse the surface, pointer mapping, authentication and permissions. Add Windows and Ubuntu capture after macOS works.
- When stable: merge tested features into main, increment to 0.7.0 with next build number, run existing single gated GitHub workflow, publish IPA/APK + desktop agents, verify release + altstore feed and perform normal personal usage tests.

## Roadmap rescope
Previous roadmap: 0.7 Windows/Raspberry Pi/ARM/direct SSH; 0.8 TVs/entertainment; 0.9 remote desktop; 1.0 stable; 1.1 presentation. Revised 0.7 prioritizes Snapshot, Media, Live while preserving existing OS support. Defer new TV platforms, full remote desktop extras, clipboard and file transfer until after visual control. No Wake-on-LAN. Shutdown stays under existing simple power controls.
