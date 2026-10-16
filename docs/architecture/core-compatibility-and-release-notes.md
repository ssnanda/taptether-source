# TapTether macOS permission cores — compatibility & release notes

> Keep this log with every change to the **actual code** of Input Core or Screen Core.
> Changes to the regular mobile app, Go agent, UI, screen transport, or tray
> should **not** update these two independently approved executables.

## Stability contract

| Executable | macOS permission | Stable installation | Independent version |
| --- | --- | --- | --- |
| `taptether-input-core` | Accessibility | `~/.local/bin/taptether-input-core` | `INPUT_CORE_VERSION` |
| `taptether-screen-core` (migration in progress) | Screen & System Audio Recording | `~/.local/bin/taptether-screen-core` | `SCREEN_CORE_VERSION` |

- Each core has its **own** version and user approval. Never tie its
  version number to the regular `VERSION` or app build number.
- Normal install/update/repair: preserve the installed executable and
  running LaunchAgent. **No replacing, re-signing, resetting TCC, or
  unnecessarily restarting the core.** Packaging a new release must not
  recursively re-sign a core inside the Finder application.
- To modify core implementation or signing identity: make a deliberate
  version increment, append a dated note below describing why it was
  unavoidable, test the new version, and ask for explicit permission to
  replace an already installed core. Never silently update it.
- Installer must refuse to replace a core with the **same version**.
- Preserve existing saved pairing, TLS certificates, keys, and input
  permissions through normal updates.
- A replacement or signing-identity change may require the user to
  approve macOS Accessibility/Screen Recording again. Tell the user
  **before** upgrading and list which entry should appear in System Settings.
- `codesign --force --deep` must not be used on packaging/repair paths:
  it can re-sign nested helpers even when only the outer app changed.
- A new release note must explicitly say **Input Core: unchanged** and
  **Screen Core: unchanged** or list the independently approved new versions
  and manual permission step.

## History

### 2026-10-16 — TapTether 0.7.1 UI/agent maintenance

- Input Core **1.0.0 — unchanged code and version**.
- Screen Core **not yet released**; separate stable Screen Core implementation
  is under review, not part of the 0.7.1 UI change.
- Removed unnecessary Input Core LaunchAgent restart during ordinary
  agent install/repair/start.
- Removed recursive Finder bundle signing and refused same-version Input Core
  replacement. Existing signed Input Core and its TCC grant are preserved.
- Why: Screen Recording and Accessibility approvals had to be removed and
  re-added on macOS after agent changes. A changed code signature is a
  possible cause, not a confirmed root cause.
- User action: **none** for an ordinary agent update. Do not remove either
  permission unless macOS actually reports a permission issue.

### Input Core 1.0.0 — stable baseline

- Separate accessibility-approved executable that receives authenticated
  local input from the normal TapTether agent.
- Existing installations should retain approval across agent upgrades.

### Screen Core 1.0.0 — planned initial migration

- Independently approved ScreenCaptureKit capture process with authenticated
  local-only IPC, no screenshots persisted.
- One-time macOS Screen Recording consent will be needed **when installed**.
- After migration, routine agent upgrades should not replace/re-sign it.
