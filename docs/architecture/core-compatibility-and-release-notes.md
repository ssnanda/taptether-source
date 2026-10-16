# macOS Core releases (protected, separate from TapTether app version)

Input Core and Screen Core each have independent macOS permission grants and
independent executable versions. Neither is a routine part of an agent update.

| Permission | Executable | Stable version file | Consent |
| --- | --- | --- | --- |
| Mouse and keyboard | `taptether-input-core` | `INPUT_CORE_VERSION` | Accessibility |
| Screen capture | `taptether-screen-core` | `SCREEN_CORE_VERSION` | Screen & System Audio Recording |

Normal reinstall/update must not replace, re-sign or restart either running
core. The installer refuses same-version replacements; only an explicit
`upgrade-core --authorize VERSION` or
`upgrade-screen-core --authorize VERSION` permits a new binary.
The outer Finder application is signed without `--deep` to avoid re-signing
embedded helpers. Keep pairing identities, local secrets and certificate pins.

## Core change notes

### Input Core 1.0.0 — unchanged on 2026-10-16
Existing stable Accessibility executable. No changes to the protected Input
Core implementation for the 0.7.1 capture migration.

### Screen Core 1.0.0 — initial migration, 2026-10-16 (draft)
New independently signed ScreenCaptureKit executable, local authenticated
UNIX socket and bounded in-memory screenshot transport. No cloud or disk
storage. Uses the ordinary agent for all phone authentication.
**One-time permission:** approve `taptether-screen-core` under macOS
System Settings → Privacy & Security → Screen & System Audio Recording.
After first approval, regular agent upgrades must preserve the executable,
signing identity, and running Screen Core service. Initial migration requires
physical testing before publication.

**All subsequent Core changes:** increment the respective CORE_VERSION,
add a dated note here detailing why a core update was unavoidable and
whether macOS requires reapproval. Never silently change a protected core.
