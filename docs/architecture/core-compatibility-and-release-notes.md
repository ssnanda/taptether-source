# TapTether macOS protected core release notes

The regular TapTether app and agent can update without replacing either
macOS-permission-approved executable. They must remain independent.

| Helper | Approved macOS permission | Independently pinned version |
| --- | --- | --- |
| `taptether-input-core` | Accessibility | `INPUT_CORE_VERSION` |
| `taptether-screen-core` | Screen & System Audio Recording | `SCREEN_CORE_VERSION` |

## Mandatory change rules

1. Routine updates do not overwrite, re-sign, or restart the existing running
   Input Core or Screen Core. Sign only the outer Finder app, never nested
   helpers with `codesign --deep`.
2. Both helpers keep their path in `~/.local/bin` and their own version
   independent of the regular `VERSION` number.
3. An Input Core or Screen Core implementation change **must** increment the
   corresponding CORE_VERSION, include a dated note here, and receive
   explicit user approval before the installed core is replaced.
4. The installer must refuse pointless same-version Input Core replacements.
   Screen Core is currently installed only when absent; replacement needs
   a separately reviewed upgrade mechanism, not routine uninstall/reinstall.
5. Never reset macOS Accessibility or Screen Recording TCC entries, the pairing
   identity, TLS certificate, or other local state automatically.
6. Release notes must explicitly say **Input Core: unchanged** and
   **Screen Core: unchanged**, or list each new independent version and what
   macOS permission reapproval may be needed.
7. If either permission fails, diagnose installed executable identity and
   TCC status before requesting a reinstall.

## Change history

### 2026-10-18 — Screen Core 2 (optional high-detail capture)

- **Input Core 1.0.0: unchanged.**
- **Screen Core 2: changed with independently versioned authorization.**
- Adds a bounded 1920×1080 on-demand JPEG capture, preserving 1280×720
  Live/default Snapshot. The authenticated local socket accepts a fixed
  `capture-detail` request with the existing private token and peer checks.
- **Routine updates never replace an installed Screen Core, even when a
  new v2 binary is bundled.** It is explicitly installed only by:
  `taptetherctl-mac upgrade-screen-core --authorize 2`, after installing
  the latest Agent.app. This command verifies the incoming signature,
  preserves the previous binary as a backup and restarts only Screen Core.
- **macOS permission impact:** Changing the independently signed Screen
  Core executable *may require the owner to approve Screen Recording again*.
  The command is not run automatically. No TCC entries are deleted,
  no pairing/certificate keys are rotated, and Input Core is not touched.
- Existing Screen Core v1 continues to support the ordinary 720p
  Snapshot/Live features. The new HD action explicitly reports when v2 is
  absent. The owner requested these pending 0.7 coding improvements; replacing
  the installed protected helper remains a distinct opt-in action.


### 2026-10-16 — Upcoming 0.7.2 maintenance (draft)

- **Input Core 1.0.0: unchanged executable implementation and version.**
- **Screen Core 1.0.0: unchanged executable implementation and version.**
- Changed only installer and packaging: preserve running core services rather
  than forcibly restarting them every time the agent is repaired/updated.
- Do not recursively re-sign nested helpers when the Finder .app is built.
- Do not replace Input Core if its installed version is already current.
- Added regression checks and CI enforcement for future code changes.
- **Permission impact:** no new permission should be required on a routine
  update. The previously reported need to re-add macOS Accessibility and
  Screen Recording entries could reflect stale TCC records or signing identity,
  but no definitive root cause has been established.

### 2026-10-16 — Published 0.7.1+61

- Initial separate Screen Core 1.0.0 with one-time Screen Recording consent.
- Input Core 1.0.0 continues as independently approved Accessibility helper.
- Both use local-only IPC. Routine agent updates should preserve both binaries.

## Future changes

Append a dated entry `## Input Core <new version>` or
`## Screen Core <new version>` before approving a core implementation change,
including the reason, migration plan, and required macOS action.
