# TapTether 0.7.22+85 — Open on computer must open the website

Previously **Media → Netflix → Open on computer** called the same-tab navigation handler. That handler focused the default browser and immediately injected Cmd+L, typed a URL, then Return (Ctrl+L on Windows/Linux). During application activation or video fullscreen, this could reach the wrong window and trigger an **Open** dialog instead of loading Netflix.

The explicit **Open on computer** button now uses the already-authenticated desktop agent's allowlisted **/api/media/open** browser URL launcher, with service `netflix` or `youtube`, and no simulated keypresses. Browser opening may create a new tab; this is safer than typing into an unfocused app. Search, shared-link playback, history Back and profile chooser retain their same-tab navigation behavior.

An added Flutter widget regression ensures Open on computer dispatches the service action and **zero remote key events**. The agent does not accept arbitrary URLs from this action. No protected macOS Input Core or Screen Core changes, and no credentials/remote telemetry.
