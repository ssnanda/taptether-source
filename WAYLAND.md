# TapTether 0.3 — GNOME Wayland / Ubuntu 26.04

TapTether on Linux now supports native `/dev/uinput` virtual devices. This works with GNOME Wayland and X11 without the RemoteDesktop portal used by apps that call XTEST. It does not fix unrelated dialogs from Steam Input or other apps. The hardware-style keyboard/media events may work on the lock screen; keep your pairing token private and restrict port 48321 to trusted LAN devices.

## Install/update from Mac

Run `./bin/5-tt-remote-install-ubuntu.sh sandip@192.168.68.87` from the TapTether repository. The script builds Linux amd64 and arm64 installers, copies the detected architecture over SSH, installs it, adds your Ubuntu user to the restricted `taptether` group, configures `/dev/uinput`, and creates the per-user desktop autostart and dock launcher.

**First-time security setup requires sudo.** Log out of the Ubuntu graphical desktop and log back in (or reboot) to apply group membership. A running SSH shell cannot acquire newly added supplementary groups without a new login. It does not run the agent as root. `taptether` group membership grants access to a powerful virtual keyboard/mouse interface; only grant it to trusted users.

## SSH commands

- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl status'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl start'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl restart'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl permissions'`
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl pairing'` (PRIVATE TOKEN — never share in a chat)
- `ssh sandip@192.168.68.87 '~/.local/bin/taptetherctl logs'`

The service starts on graphical desktop login through the user's autostart entry, not at the graphical login screen. The Ubuntu dock shortcut launches it on demand. No cloud component is required.

## Limitations

- Keyboard layout for hardware text synthesis is US-English ASCII only in 0.3. Unicode text input needs a future method. Physical host keyboard layouts may change mappings.
- Go builds compile and unit tests run on Linux; end-to-end uinput and libinput integration must be tested on a real GNOME Wayland desktop.
- Input injection is privileged by Linux device permissions; do not expose `/dev/uinput` to all users, run this service as root, or expose port 48321 publicly.
- Volume controls synthesize `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN`, and `KEY_MUTE` media key events. Desktop sound settings and the active audio sink determine actual volume effects.
- Existing iOS/Android apps must be rebuilt to show the new volume buttons. Pairing credentials persist on Ubuntu unless its user config directory is removed.
- If GNOME keeps showing Remote Desktop prompts even when TapTether is not involved, investigate Steam Input or other XWayland/XTEST clients separately.
