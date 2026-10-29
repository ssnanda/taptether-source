# TapTether developer commands

These are the everyday entry points. The older numbered release helpers remain in place because GitHub Actions and packaging scripts call them.

| Order | Command | Function |
|---|---|---|
| 1 | `./bin/1-pull-latest.sh` | Safely sync GitHub main; preserve local commits and edits |
| 2 | `./bin/2-bump-version.sh [patch\|minor\|major]` | Bump and push the source version (does not publish) |
| 3 | `./bin/3-install-iphone.sh` | Signed Release build and USB installation on iPhone (runs from Home Screen) |
| 3 | `./bin/3-install-iphone.sh --installer usb --publish` | Install iPhone Release app, then request public GitHub release (opt-in) |
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

## Publishing after testing on iPhone

The public `current` release already contains `0.8.34+194`; the next version is **0.8.34+195**. To publish it after testing:

1. Run `./bin/1-pull-latest.sh` to get the latest source.
2. Run `./bin/3-install-iphone.sh --installer usb --publish` with the iPhone connected.
3. After the USB installation succeeds, the installer requires a clean, up-to-date source `main`, checks the public release version, then requests `task=release` using GitHub CLI. It DOES NOT directly publish the development-signed IPA.
4. The GitHub workflow separately creates an **unsigned public IPA**, Android APK, and all supported agent installers. Publication completes only if the workflow succeeds. Watch `https://github.com/ssnanda/taptether-source/actions/workflows/taptether.yml` and then check `https://github.com/ssnanda/taptether.com/releases/tag/current`.

`--publish` is optional; a normal iPhone installation only installs locally. Version bumps and pull requests **no longer automatically publish**. GitHub Actions minutes are used when requesting a full release. The private repository must have `TAPTETHER_PUBLIC_RELEASE_TOKEN`, and `gh auth login` must have sufficient workflow permissions. The public IPA is unsigned and requires separate signing for installation on other phones.

## Public IPA and Actions cleanup

The public iOS download is `https://github.com/ssnanda/taptether.com/releases/download/current/TapTether.ipa`. That asset already exists in the older public `current` release, but **source version 0.8.34+195 is not published until a full release workflow succeeds**. The public IPA is unsigned (for redistribution with each recipient's own signing method), **not** the personally signed USB IPA installed on your iPhone.

If you already installed and tested the current source version, you can request publishing **without reinstalling** using:

```bash
gh workflow run taptether.yml -R ssnanda/taptether-source --ref main -f task=release
gh run list -R ssnanda/taptether-source --workflow taptether.yml --limit 5
```

The request queues a new CI build: a successfully queued workflow is **not** an uploaded IPA. Watch the full workflow to confirm its `build-and-publish` job completed and confirm the public release title and downloadable IPA match `VERSION`.

The repository has **one workflow file**; old entries visible in GitHub Actions are *workflow run history*, not additional workflow definitions. To remove historical completed workflow runs and temporary Actions artifacts without compiling the app or agents, use:

```bash
gh workflow run taptether.yml -R ssnanda/taptether-source --ref main -f task=cleanup
```

This requires GitHub Actions permissions. Cleanup preserves active runs and published downloads/AltStore metadata, but deletes completed logs and temporary artifacts; it **does not refund consumed GitHub Actions minutes**. Weekly cleanup and post-release cleanup continue automatically. The maintenance PR adding this option also requests a one-time cleanup of older runs on merge.

## Notes
`VERSION` is the single authoritative app version; `app/pubspec.yaml` is kept in sync and the iPhone installer passes that same version and build number to Flutter. The iPhone installer verifies the signed `Runner.app` metadata before installing. For the newest app: run `./bin/1-pull-latest.sh` and then `./bin/3-install-iphone.sh --installer usb` **without** `--skip-build`. `--skip-build` is allowed only when both the signed build mode and exact source version match. Pulling source never builds or installs the app.

`1-pull-latest.sh --dry-run` fetches remote information but does not modify local source files. Neither pulling nor the standalone build wrappers publish a release. Samsung Tizen packaging is not exposed as a working builder because the existing Samsung script currently exits without producing a package. Do not delete internal `2a-*`, `2b-*`, `2c-*`, and other legacy helpers: CI still depends on them.
