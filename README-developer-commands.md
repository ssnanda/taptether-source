# TapTether developer commands

These are the everyday entry points. The older numbered release helpers remain in place because GitHub Actions and packaging scripts call them.

| Order | Command | Function |
|---|---|---|
| 1 | `./bin/1-pull-latest.sh` | Safely sync GitHub main; preserve local commits and edits |
| 2 | `./bin/2-bump-version.sh [patch\|minor\|major]` | Bump and push to the source repository (triggers existing release CI) |
| 3 | `./bin/3-install-iphone.sh` | Signed Release build and USB installation on iPhone (runs from Home Screen) |
| 4 | `./bin/4-build-all-agents.sh` | Build macOS, Ubuntu and Windows installers |
| 4 | `./bin/4-build-agent-macos.sh` | macOS Intel and Apple Silicon agents |
| 4 | `./bin/4-build-agent-ubuntu.sh` | Ubuntu amd64/arm64 packages |
| 4 | `./bin/4-build-agent-windows.sh` | Windows ZIP packages |
| 4 | `./bin/4-build-android.sh` | Android APK without publishing |
| 5 | `./bin/5-install-agent-ubuntu.sh USER@HOST` | Remote Ubuntu installation via SSH |
| 9 | `./bin/9-doctor.sh` | Diagnostics |
| 9 | `./bin/9-test.sh` | Tests |
| 9 | `./bin/9-build-lg-companion.sh` | Experimental LG webOS companion, not a global input agent |

## First-time iPhone setup
On a Mac, install Flutter and full Xcode. Open `app/ios/Runner.xcworkspace` after Flutter generates the iOS project, choose the Runner app target and configure **Signing & Capabilities** with **Automatically manage signing** and your existing Xcode Apple development team. Connect the iPhone by USB, trust this Mac, unlock it and enable Developer Mode. No passwords or two-factor codes are requested by the script.

Use `./bin/3-install-iphone.sh --list-devices` and `--device ID` when multiple phones are connected. Use `--no-launch` to install only or `--dry-run` to inspect without building or installing. By default, `3-install-iphone.sh` builds a signed **Release** app, which can launch directly from the iPhone Home Screen. Use `--installer usb` to bypass a devicectl Developer Disk Image error with `ideviceinstaller` (requires `brew install ideviceinstaller libimobiledevice`). The optional `--build-mode debug` is only for launching with Flutter/Xcode tooling. `--skip-build` reuses an app only when its saved build-mode record matches the requested mode, preventing accidental reuse of Debug apps. The build log is `app/build/iphone-install-build.log`. Installation updates an existing matching bundle ID without uninstalling it. Switching bundle IDs can create a separate app; back up credentials before changing identifiers.

## Notes
`1-pull-latest.sh --dry-run` fetches remote information but does not modify local source files. Neither pulling nor the standalone build wrappers publish a release. Samsung Tizen packaging is not exposed as a working builder because the existing Samsung script currently exits without producing a package. Do not delete internal `2a-*`, `2b-*`, `2c-*`, and other legacy helpers: CI still depends on them.
