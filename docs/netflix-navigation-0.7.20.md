# TapTether 0.7.20+83 — Netflix navigation corrections

- **Back** in Media Remote no longer opens /browse and loses the prior search/list. It focuses the already-running default browser, sends Escape to leave Netflix video fullscreen, waits briefly, and uses browser-history Back: `cmd+left` on macOS and `alt+left` elsewhere. Firefox on macOS supports Cmd+Left. This preserves the actual previously visited page (browse, title details, results) when it exists. It cannot reproduce Netflix's in-page React navigation for every possible page history.
- **Enter fullscreen** and **Exit fullscreen** explicitly activate the existing default browser before sending Netflix `f` or `Escape`. This does not create extra browser tabs or change OS fullscreen. It is still sensitive to the Netflix player's keyboard focus, so a browser/Netflix UI click may be necessary when shortcuts aren't active. The protected macOS Input Core and Screen Core remain unchanged.
- Former **Choose profile** control did nothing except reopen /browse and display instructions. Relabeled to **Manage profiles**, which actually opens the established first-party `https://www.netflix.com/profiles/manage` destination in the same tab. A user still selects/edits a profile on the computer via Trackpad/Live. Switching directly to another profile through the browser requires a separate opt-in browser integration; the app cannot inspect Netflix's session or click a profile card reliably via generic keyboard control.
- Added Flutter widget regression coverage for the navigation / fullscreen callbacks and profile URL.
- No credentials, cookies, external scripts, telemetry, browser extension or macOS protected core changes.

## 0.7.21+84 correction: select, not edit

- Earlier **Manage profiles** opened `/profiles/manage`, which is an edit screen, not the requested selector.
- Restored button label **Choose profile** and changed the target to the Netflix `https://www.netflix.com/ProfilesGate` (Who's watching?) route, using the existing focused browser tab and exiting video fullscreen first.
- Netflix does not provide TapTether with a documented profile-selection API, and web layouts/routes can change. If Netflix redirects this address to Browse, use the top-right profile avatar and select a different profile with Trackpad, as Netflix's official browser instructions describe.
- Never access Netflix session tokens or attempt automatic profile switching. No protected macOS core changes.
