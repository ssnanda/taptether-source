# TapTether Media 0.7.16+79 — compact playback and shared links

## Duplicate-tab prevention

The Media **Open on computer** action no longer uses the desktop OS
open-URL launcher. It focuses the user's configured default HTTPS browser
and navigates its **currently selected tab**, avoiding the additional tab
typically created by opening netflix.com with LaunchServices.

On macOS, the authenticated desktop agent asks LaunchServices for the
default HTTPS browser bundle ID and activates it with `open -b` (no URL);
then the connected phone sends Cmd+L, the allowlisted page URL and Return
using the already-paired input channel. For Firefox this reuses the
selected/restored tab instead of opening a new one. TapTether never
enumerates browser tabs or steals credentials. If another Firefox tab
also contains Netflix, TapTether cannot detect or select it without a
separately permissioned browser integration. On Linux and Windows the
browser is expected to be foreground; there is no automatic
default-browser activation in this version.

## Share a title from the iPhone Netflix app

1. Find a title inside the Netflix iPhone app.
2. Choose Share → Copy Link.
3. Tap the TapTether Media → Netflix → Play from shared Netflix link
   expansion panel, then **Paste**.
4. Choose **Play on computer** (normalized `/watch/<titleId>`) or
   **Open details** (normalized `/title/<titleId>`).

The parser accepts `https://www.netflix.com/us/title/81676409?... `
and compatible regional title/watch URLs, strips the query/marketing
parameters, and forwards only a fixed Netflix host and numeric ID.
It accepts YouTube watch/Shorts/short links and canonicalizes them to
`https://www.youtube.com/watch?v=...`. No outbound requests, catalog
scraping, DRM interaction or persistent link storage occur in TapTether.

Netflix playback may still show sign-in, a profile chooser, a details
page, or an episode selection. The browser account must already be
licensed to view the title and the title must be available in that region.
TV playback is a **future LG webOS integration**; it is not implied by
these desktop-browser links.

## Compact remote

Keep the YouTube/Netflix selector, **Open on computer**, **Search page**,
and gated search in a small upper section. Collapse shared-link entry.
Show one main playback row (Back, Rewind 10s, Play/Pause, Forward 10s,
Exit full screen) and compact volume controls. Hide profile, close tab,
Full screen, Skip Intro, next/captions in **More video controls**.
Retain the shared Mouse and keyboard trackpad immediately below.
No protected macOS Input Core or Screen Core source/versions changed.
