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
