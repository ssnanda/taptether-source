# TapTether 0.7.12+75 — automatic biometric unlock

When **Require app unlock** and **Biometric unlock** are both enabled,
TapTether automatically requests the phone's native Face ID / Touch ID
prompt whenever the application first opens locked or the configured
background-lock interval expires.

- No initial tap on “Use Face ID / Touch ID” is required.
- The biometric prompt is attempted **once per lock event**, so
  cancellation, a failed scan, platform lockout, or an OS lifecycle
  notification cannot trigger an authentication loop.
- A failed or canceled biometric prompt reveals and focuses the existing
  secure six-digit app PIN input. “Try Face ID / Touch ID again” remains an
  explicit option.
- When biometrics are disabled, the PIN is available immediately.
- If secure storage fails, the existing “Retry secure storage” path remains
  available; the app never bypasses its lock.
- Fingerprints, Face ID data and app PINs remain with iOS/Android and
  local secure storage. No account, cloud unlock, server-side change,
  weaker pairing, or telemetry is introduced.

The app relies on local_auth's biometric-only authentication. This work does
not modify the computer agents or macOS Input/Screen Core. It ships as a
coordinated 0.7.12+75 IPA/APK update. Agent versions may differ until the
next full update.

Regression tests exercise a successful biometric prompt without a manual
tap, PIN-only fallback after cancellation, and a fresh single biometric
prompt on a later relock. Physical Face ID testing is required after
publishing the IPA.
