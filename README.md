# TapTether

Your devices. Your control. Your network.

LAN-first remote control from a Flutter iPhone/Android client to authenticated Linux and macOS input agents.

## 0.5.0+12

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

## Current-release publishing and AltStore (0.3.3+9)

IPA/APK build scripts now validate Flutter syntax, build current agents, bundle them, build mobile outputs and publish to one rolling GitHub release via authenticated GitHub CLI.

    ./bin/2a-tt-ipa.sh
    ./bin/2a-tt-apk.sh

Build without release upload:

    ./bin/2a-tt-ipa.sh --no-publish
    ./bin/2a-tt-apk.sh --no-publish

A successful IPA build always creates altstore.json from its actual Info.plist bundle ID, app version, build number and file size. Release tag current holds only latest TapTether.ipa, TapTether.apk, two Ubuntu DEBs, two macOS archives and TapTether-icon.png. Superseded local TapTether packages are removed. The GitHub Actions release workflow builds and uploads the same assets after a successful macOS, iOS and Android build.

Local publishing requires authenticated GitHub CLI (gh auth login) or GH_TOKEN in CI. Use the --no-publish flag to skip the upload step.

**Public release:** TapTether.com is now public. The public AltStore feed is at https://raw.githubusercontent.com/ssnanda/taptether.com/main/altstore.json and the current IPA is at https://github.com/ssnanda/taptether.com/releases/download/current/TapTether.ipa.

## App startup update check and agent updates (0.4.0)

When the mobile app opens, it makes one small outbound HTTPS request to the public GitHub AltStore feed. It compares the actual installed iOS/Android version with the current published release and displays a banner only when a newer version exists. Tapping opens the current release; iOS continues to require signing via AltStore, so the app does **not** silently install IPAs. No identifiers or analytics are sent; the application still works offline. The user specifically requested this exception to the LAN-only behavior.

After pairing, the phone uses the authenticated LAN /api/info endpoint to learn the installed agent version and whether remote shutdown is enabled. If the agent is older than the public release, a banner explains how to upgrade. Existing older agents remain usable but do not expose /api/info.

**Ubuntu via SSH**: once the newest installer has been deployed, use:

    ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl check-update'
    ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl update'

The updater reads the public GitHub Release API only when invoked, downloads the correct architecture and verifies the exact SHA-256 digest reported by the Release before installing, restarting the service and preserving the local TLS and pairing files.

**Upgrade an earlier Ubuntu installation** from the Mac first (earlier controllers do not know the new command):

    ./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87

That installs the new agent and copies the update helper to the computer. Thereafter, use the SSH check-update/update commands above.

**macOS agent** (after installing the new three-file macOS archive):

    ~/.local/bin/taptetherctl-mac check-update
    ~/.local/bin/taptetherctl-mac update

The macOS updater checks the matching architecture archive, verifies SHA-256, installs and restarts the LaunchAgent. It does not alter the pairing identity. Updates are manual/opt-in; agents do not poll the internet unattended.

## Shutdown from your phone (disabled by default)

The app shows a computer Shutdown button, disabled unless the authenticated local agent advertises that the owner has enabled it. Tapping it requires a confirmation dialog explaining that unsaved work may be lost. This sends an authenticated request over the previously pinned local HTTPS session.

For Ubuntu, enable or disable the permission over SSH:

    ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl enable-shutdown'
    ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl disable-shutdown'

The enabled state is persisted as a restricted systemd Environment override. A narrow polkit rule grants the designated TapTether service user/group only the logind power-off action. It does not grant general sudo privileges. A paired phone can then power off the machine even from the lock screen. This setting is **off by default**.

For macOS, use the corresponding taptetherctl-mac enable-shutdown / disable-shutdown commands, and approve macOS System Events Automation if prompted. Actual shutdown authorization is controlled by macOS and may fail when no graphical login session is available.

Neither remote shutdown nor updates have been tested end to end on your machines. Restrict port 48321 to trusted LAN devices and treat pairing secrets as authority to control the computer.

## Unified product icons (0.4.1)

TapTether app and agent icon artwork is stored under assets/branding in compact base64-encoded files. This preserves the generated artwork as repository source without Git LFS. The script bin/9-tt-brand-icons.py decodes it and uses Pillow to generate:
- Real iOS AppIcon asset catalog PNGs at every declared scale, for the installed IPA icon;
- Android standard launcher mipmap icons, for the installed APK;
- Flutter's assets/branding/taptether.png for the in-app header;
- A macOS TapTether.icns included in the agent tarball; the installation creates the branded clickable ~/Applications/TapTether Agent.app launcher;
- A 512-pixel Ubuntu GNOME dock icon supplied and installed by the SSH setup;
- LG webOS icon.png and largeIcon.png for the companion TV app;
- The published TapTether-icon.png used by the public AltStore feed.

Run python3 -m pip install Pillow once on a Mac if it is not installed. Both mobile build scripts run the icon generator automatically. GitHub Actions installs Pillow and validates all expected platform outputs before building or publishing. Generated image sizes are not committed; only their approved artwork sources are versioned.

## v0.5 phase one — discover and remember trusted computers

TapTether now supports:
- A "My Devices" dashboard with one-tap reconnection and explicit device removal.
- On-demand LAN discovery via a small UDP probe on port 48322, requiring no hosted server. The agent responds with its hostname, platform, version and service port **but never shares tokens, keys or certificate fingerprints**.
- The phone tries LAN broadcast and limited /24 on-link unicast probing, to accommodate networks that block broadcasts. Discovery is best effort; manual IP entry remains available.
- Secure saved pairing profiles after **both** the pinned TLS certificate and the agent's existing bearer token have been verified by a successful ping. iOS Keychain and Android secure storage protect saved tokens and pins.
- Platform network permissions generated into the iOS and Android runners as part of the icon/build preparation.

**On Ubuntu:** Install the latest agent using
\`./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87\` from the Mac. Allow trusted LAN UDP/48322 inbound if your host firewall blocks discovery; do not open it to the public Internet.

**Compatibility:** Old agents still accept manual IP+token+fingerprint pairing, but will not appear in discovery until upgraded. The pairing tokens and certificate identities remain unchanged when upgrading.

**Remaining v0.5 features (not yet shipped):** Native public/private per-device key credentials, first-time pairing approval/QR enrollment, and SSH installation directly from the mobile app. For those capabilities, follow a separate protocol update with replay protection, device revocation, host-key verification, and user-authorized sudo operations. Do not interpret broadcast discovery as proof of device identity or silently install software on discovered hosts.

**Privacy:** App launch version checking is the only intentional public GitHub request; discovery and remote control stay on the local network. No discovery data is used for telemetry.
