# TapTether

**Your devices. Your control. Your network.**

Private LAN-only remote-control prototype. Single repository containing a Flutter iOS/Android app, a Go TLS-enabled agent and shell scripts for packaging multiple operating systems. Repository: `github.com/ssnanda/taptether.com` (private).

## Bootstrap on macOS

1. Place `bootstrap-taptether.sh` in `/Users/sandip/Projects/taptether`.
2. `cd /Users/sandip/Projects/taptether`.
3. `bash bootstrap-taptether.sh`.
4. `./bin/0-doctor.sh` (use `--repair` if native Flutter runners weren't created).
5. `./bin/4-test.sh`.
6. `./bin/3-push-project.sh` to commit and push initial source files.

Requires git, Go 1.22+, Flutter SDK, Android SDK for APK, and Xcode/macOS for IPA. On Ubuntu, install `xdotool` and use an **X11/Xorg desktop session**, not Wayland, for input injection in this first version.

## Scripts

| Script | Function |
|---|---|
| `./bin/0-doctor.sh` | Check prerequisites; `--repair` creates Flutter runners |
| `./bin/1-bump-version.sh [patch\|minor\|major]` | Increment VERSION and Flutter build number; git commit **and push main** |
| `./bin/2a-tt-ipa.sh` | Create **unsigned** IPA by default for later signing (e.g. AltStore) |
| `./bin/2a-tt-ipa.sh --signed` | Flutter signed IPA; needs Xcode signing configured |
| `./bin/2a-tt-apk.sh` | Build Android APK to `dist/android` |
| `./bin/2b-tt-ubuntu.sh` | Build Ubuntu/Linux agents **and two `.deb` installers** |
| `./bin/2b-tt-deb.sh` | Package Ubuntu `.deb` from prebuilt Go binaries |
| `./bin/2b-tt-windows.sh` | Build Windows agents (backend not yet implemented) |
| `./bin/2b-tt-macos.sh` | Build macOS agents (backend not yet implemented) |
| `./bin/2c-tt-android-tv.sh` | Experimental Android TV APK (phone layout) |
| `./bin/2c-tt-lg-tv.sh` | Explain TV vendor SDK prerequisites, no fake build |
| `./bin/2c-tt-samsung-tv.sh` | Explain TV vendor SDK prerequisites, no fake build |
| `./bin/3-run-agent.sh` | Start Go agent on current computer |
| `./bin/3-push-project.sh` | Review and commit all nonignored project files to main |
| `./bin/4-test.sh` | Go tests + Flutter analyze/tests (when Flutter installed) |
| `./bin/2d-tt-all.sh` | Build all available Go targets, Ubuntu installers and available mobile targets |

## Try Ubuntu remote control

1. Copy repository/build agent to an Ubuntu computer running a graphical X11 desktop, and `sudo apt install xdotool`.
2. On Ubuntu, run `./bin/3-run-agent.sh` or the built `TapTetherAgent-linux-amd64-*` binary.
3. The agent prints its *private LAN IP*, secret pairing token, and TLS certificate fingerprint.
4. Install/run TapTether on your iPhone or Android phone, enter these three values, and connect using local Wi-Fi.
5. Keep the token secret. Firewall TCP port 48321 to trusted devices on the LAN.

The agent stores its identity and token in the current OS user's configuration directory (`~/.config/taptether` on most Linux desktops), **not the git repository**. There are no analytics, cloud endpoints, update pings, or arbitrary remote shell commands. TLS encryption and manual certificate fingerprint pinning are mandatory. Pairing values are kept only in memory by this prototype; reenter after relaunch.

## Important scope notes

- **Working MVP path:** iOS/Android UI ⇄ authenticated HTTPS local agent ⇄ Ubuntu **X11 + xdotool** keyboard/mouse.
- **Wayland**, Windows/macOS native input, device auto-discovery, clipboard sync, TV remote adapters, and polished TV-specific app builds are future work. Windows/macOS binaries compile but do **not** provide remote input yet.
- The input backend has not been tested on physical hardware. Review/verify on a private LAN before relying on it.
- An unsigned IPA is *not* independently installable; use AltStore or valid code signing. A signed IPA requires configured Xcode signing.
- TV operating systems can have compatibility or background-service restrictions; see `tv/README.md`.
- Build-time dependency downloads (Flutter/Go toolchains) are distinct from runtime communications. This app intentionally has no runtime cloud integration.

## GitHub safety

The bootstrap creates the SSH remote `git@github.com:ssnanda/taptether.com.git` unless an allowed matching origin is already present. It does **not** push automatically. `1-bump-version.sh` commits **only the version files** and pushes to `main`; run `3-push-project.sh` for other source changes. It refuses to push to a different repository. On the **first** commit only, `1-bump-version.sh` stages the initial scaffold so the new private repository is usable.