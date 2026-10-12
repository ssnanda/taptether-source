# TapTether 0.3.1 — Ubuntu Wayland/X11 and automatic background service

TapTether uses Linux `/dev/uinput` for native keyboard, mouse, and volume events on Wayland or X11. It does not use the GNOME RemoteDesktop portal. The service runs as your normal Ubuntu user, not as root, and is given only the `taptether` supplementary group to access `/dev/uinput`.

## Install and pair in one step

From the TapTether repository on macOS: `./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87`

The command builds the matching .deb, transfers it over SSH, validates and installs it, configures restricted `/dev/uinput` permissions, migrates any old user service, installs the GNOME application launcher, enables the systemd service at boot, starts it immediately in the background, confirms it is running, and displays the LAN IP, HTTPS port, pairing token, and TLS SHA-256 certificate fingerprint. You should **not** need to log out to start the new service.

The agent stores credentials in `~/.config/taptether/`. **Treat the pairing token as a password.** Installation terminal output contains it; never paste it into chats or logs.

## SSH management

- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'` — displays private pairing details
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl status'` — status and boot-enabled state
- `ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl restart'` — requires sudo
- `ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl stop'` — requires sudo
- `ssh -t sandip@192.168.68.87 '~/.local/bin/taptetherctl start'` — requires sudo
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl logs'` — view safe service logs

## Security and limitations

The system service starts **at boot**, including before desktop login, and Linux virtual HID events can affect the lock/login screen. Protect the token and restrict inbound TCP 48321 to trusted LAN devices; never expose it to the public internet. The agent does not need to run as root, nor does the SSH user need unrestricted `/dev/uinput` access.

This version's virtual keyboard text synthesis primarily supports US-English ASCII. Actual end-to-end Ubuntu Wayland input, volume controls, and service boot behavior still require on-device testing. This deployment is separate from the mobile IPA/APK build. Existing mobile apps may need rebuilding to expose newer controls.
