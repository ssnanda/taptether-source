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

Requires git, Go 1.22+, Flutter SDK, Android SDK for APK, and Xcode/macOS for IPA. On Ubuntu 26.04, native `/dev/uinput` input supports GNOME Wayland and X11. Restricted permissions are configured by `bin/4-ubuntu-desktop-setup.sh`; see [WAYLAND.md](WAYLAND.md).

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
| `./bin/4-ubuntu-desktop-setup.sh` | SSH-installable Ubuntu X11 desktop launcher, graphical-login autostart, user service, pairing details |
| `./bin/2d-tt-all.sh` | Build all available Go targets, Ubuntu installers and available mobile targets |
| `./bin/4-ubuntu-desktop-setup.sh` | Configure native uinput permissions, GNOME dock and desktop autostart |
| `./bin/5-tt-remote-install-ubuntu.sh` | Build, install and configure the Ubuntu agent over SSH |


## Ubuntu desktop launcher and SSH setup

After installing the Ubuntu .deb, use the TapTether desktop setup helper from your Mac:

1. `scp bin/4-ubuntu-desktop-setup.sh sandip@192.168.68.87:/tmp/taptether-setup.sh`
2. `ssh -t sandip@192.168.68.87 'bash /tmp/taptether-setup.sh install'`

This installs `~/.local/bin/taptetherctl` for the **normal desktop user**, a user-level systemd service, a dock-launchable application entry, and an XDG graphical-session autostart file. The installer attempts to pin the launcher to the Ubuntu GNOME dock over the desktop D-Bus connection; if the session is not available, pin it later from Show Applications.

Use SSH to manage the agent: `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'`, or replace `start` with `stop`, `restart`, `status`, `logs`, or `pairing`. The `pairing` command prints the LAN IP, certificate fingerprint, **and private pairing token**; do not post the token or commit it to GitHub.

**Important:** Auto-start means **at graphical user login after reboot**, not remote control of the login screen. A logged-in **X11/Xorg** desktop session is required. Wayland, headless SSH, and controlling the screen before login are not supported in this prototype. The dock entry is a *launcher*, not a live tray-status indicator. The agent intentionally suppresses stdout in its user service so the secret pairing token isn't saved in systemd logs.

## Try Ubuntu remote control (Wayland / X11)

1. On macOS run `./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87`. It builds both Linux agents, securely copies the matching .deb over SSH and sets up restricted uinput permissions, desktop autostart and a GNOME dock launcher.
2. **Log out and log in to Ubuntu** or reboot once to activate `taptether` group membership.
3. From macOS use `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'` or just let TapTether start at graphical login.
4. Retrieve LAN IP/token/TLS fingerprint via `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'`. Keep the token private.
5. Build/install the matching TapTether iOS/Android 0.3.0+6 app to see trackpad, keyboard and volume buttons.

See [WAYLAND.md](WAYLAND.md) for permissions, SSH commands and limitations.

## Important scope notes

- **Linux path:** iOS/Android UI ⇄ authenticated HTTPS local agent ⇄ Ubuntu Wayland/X11 native uinput keyboard/mouse/media keys. X11-only xdotool fallback remains.
- Windows/macOS native input, device auto-discovery, clipboard sync, TV remote adapters, and polished TV-specific app builds are future work. Windows/macOS binaries compile but do **not** provide remote input yet.
- Native Linux uinput unit tests and cross-compilation pass; test on your actual Ubuntu desktop to verify hardware event handling. Review/verify on a private LAN before relying on it.
- An unsigned IPA is *not* independently installable; use AltStore or valid code signing. A signed IPA requires configured Xcode signing.
- TV operating systems can have compatibility or background-service restrictions; see `tv/README.md`.
- Build-time dependency downloads (Flutter/Go toolchains) are distinct from runtime communications. This app intentionally has no runtime cloud integration.

## GitHub safety

The bootstrap creates the SSH remote `git@github.com:ssnanda/taptether.com.git` unless an allowed matching origin is already present. It does **not** push automatically. `1-bump-version.sh` commits **only the version files** and pushes to `main`; run `3-push-project.sh` for other source changes. It refuses to push to a different repository. On the **first** commit only, `1-bump-version.sh` stages the initial scaffold so the new private repository is usable.
## Ubuntu install, background service and pairing (v0.3.1+7)

Use `./bin/5-tt-remote-install-ubuntu.sh user@host` from the macOS project. It builds and validates the correct .deb, installs the native Wayland/X11 Go agent, configures `/dev/uinput` permissions for a dedicated systemd supplementary group, enables a **non-root** system service to start at boot, starts the service immediately, and prints the private pairing token and TLS SHA-256 fingerprint during installation. A user logout is **not** required for this system-service setup. Use `~/.local/bin/taptetherctl pairing` over SSH to retrieve values again; start/stop/restart require sudo. The service can inject input at the login screen, so firewall port 48321 to trusted LAN clients and keep the pairing token secret. Details: [WAYLAND.md](WAYLAND.md).
