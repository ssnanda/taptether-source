# TapTether 0.7.14+77 — Netflix and YouTube media workflow

In the Media tab, Open Netflix/YouTube opens the service in the computer's
default browser. Search requires an explicit Go to Search action, which
navigates the *currently focused* browser tab using Cmd+L / Ctrl+L and the
fixed, HTTPS allowlisted search URL. Submitting a query navigates that same
tab to the search results and disarms search; this prevents an accidental
follow-on search when a video is playing. Only Open Provider may create a
new browser tab.

Back to browsing sends browser Back (Cmd+Left on macOS, Alt+Left elsewhere).
Exit full screen separately sends Escape. YouTube gets Next Video and
Captions shortcuts. Profile/account selection navigates home and instructs
the user to select the avatar in the browser using Trackpad or Live; TapTether
does not store account credentials, scrape profile lists or bypass PINs.
Close Provider requires confirmation and sends Close Tab for the currently
focused tab. It does not quit the browser or log out.

KNOWN LIMITATION: Without a permissioned browser extension TapTether cannot
read or verify the current browser URL or profile, nor can it guarantee that
the focused window is a browser. Users must keep the correct tab focused.
Full DRM playback stays on the computer; Snapshot/Live can appear blank.
No Input Core, Screen Core, certificates, pairing, agent protocol or
desktop agent code is modified. Browser behavior requires hardware testing.
