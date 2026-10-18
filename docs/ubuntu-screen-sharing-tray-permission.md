# Ubuntu — Allow/Block Snapshot and Live from the tray

TapTether Ubuntu agent **0.7.11+74** adds a local persistent privacy toggle:

**Ubuntu tray → Settings → Screen Helper → Allow screen sharing (Snapshot / Live)**

The option is **checked (allowed) by default** for existing installations.
Uncheck it to block all future Snapshot and Live screen capture from paired
phones. This does not stop the input agent, trackpad, keyboard, presentations
or media controls. It does not change desktop environment permissions.
When blocked, the active Live stream ends and the helper releases the GNOME
ScreenCast/PipeWire session; the system's screen-sharing indicator goes away.
Snapshot requests are also rejected with HTTP 403. The authenticated
`/api/info` response reports screen capture unavailable while blocked.

Rechecking the option immediately permits future requests. If GNOME asks to
share a screen again, select your display and approve that operating-system
prompt. There is no need to re-pair or restart the system service.

The preference is stored per Ubuntu desktop user at
`~/.config/taptether/screen-sharing-disabled`. The presence of this
private marker means BLOCKED. The setting is retained across agent updates,
reboots and logouts. No server/cloud accounts or telemetry are involved.
Even if the tray is closed, the local agent and graphical helper enforce
the preference. Updates do not reset it. Only the local Ubuntu user can
change it through the tray or local filesystem, not a paired phone.

The existing Screen Helper Start, Stop, Restart, and Diagnostics commands
remain available for troubleshooting.

Scope: **Ubuntu agent-only**. IPA/APK and macOS/Windows agents are not
changed. macOS already has its own native screen sharing permission control;
macOS protected Input Core and Screen Core source files remain untouched.
