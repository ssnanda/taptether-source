# TapTether

Your devices. Your control. Your network.

Private LAN-only remote control from a Flutter iPhone/Android client to authenticated Linux and macOS input agents.

## 0.3.2+8

- Responsive trackpad: adjustable 1x–8x sensitivity (default 3.8x instead of 1.7x), with queued movement rather than dropped pointer updates.
- Ubuntu amd64/arm64: Wayland and X11 native /dev/uinput mouse, keyboard and media keys.
- macOS amd64/arm64: native CoreGraphics mouse/keyboard, text and volume input compiled with Go cgo on macOS; Accessibility authorization is required.
- IPA and APK builds first build and bundle platform installer archives, plus a SHA-256 asset manifest.
- LG webOS: experimental packageable companion web application, NOT a global TV input agent.
- One-tap phone SSH installer and device-generated keypairs are NOT implemented yet. Bundled binary assets make that future step possible.

## Build on your Mac

    cd /Users/sandip/Projects/taptether
    git pull --ff-only
    ./bin/2b-tt-ubuntu.sh
    ./bin/2b-tt-macos.sh
    ./bin/2a-tt-ipa.sh

The IPA is unsigned and must be signed (for example using AltStore) before sideloading.

    ./bin/2a-tt-apk.sh

Both mobile builders automatically run bin/2e-tt-stage-mobile-agents.sh, which builds Linux agents, builds native Mac agents on macOS, copies .deb and .tar.gz archives into app/assets/agents, and writes manifest.json containing SHA-256 hashes and version metadata.

Generated agent binaries and Flutter assets are intentionally ignored by Git. Building on a non-Mac host can stage Ubuntu packages but cannot create the native Mac agents.

The GitHub Actions workflow Build TapTether agents also produces downloadable agent artifacts for Ubuntu and macOS. See the successful workflow run in GitHub Actions.

## Ubuntu over SSH

    ./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87

Install, start at boot and show pairing token and TLS fingerprint. Retrieve details later from your Mac:

    ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'

## macOS background agent

On macOS, extract the correct installer archive from dist/macos and, in the extracted folder, run:

    ./taptetherctl-mac install

This registers the background login LaunchAgent and displays the LAN IP, token and TLS certificate fingerprint. Approve the installed TapTether agent in System Settings > Privacy & Security > Accessibility before input will work.

    ~/.local/bin/taptetherctl-mac pairing
    ~/.local/bin/taptetherctl-mac status
    ~/.local/bin/taptetherctl-mac restart

## LG webOS

With LG webOS CLI installed (providing ares-package):

    ./bin/2c-tt-lg-tv.sh

The experimental TV companion .ipk is created in dist/lg-webos. Install to a Developer Mode TV through LG's ares-install CLI. It is not yet an LG system remote-control agent. See tv/README.md.

## Security

Agent requests use local HTTPS with certificate fingerprint pinning and a private pairing token. Do not expose TCP port 48321 to the Internet. In particular, Ubuntu's uinput service can synthesize keyboard and mouse input at the login screen, so its access must be restricted to trusted LAN devices. No cloud telemetry is implemented.

The Windows and Tizen OS input backends remain unimplemented. The bundled installers do not by themselves enable phone SSH provisioning. Native Mac and LG builds require their respective SDKs and must be tested on hardware.
