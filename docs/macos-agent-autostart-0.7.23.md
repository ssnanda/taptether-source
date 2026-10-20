# TapTether 0.7.23+86 — macOS agent autostart recovery

**Observed:** Mac tray periodically showed **Stopped — use Start / Repair** after the agent had been started. Current LaunchAgent uses `RunAtLoad=true` and `KeepAlive=true`, but the tray attempted recovery only once at tray startup. The user's specific Mac exit reason cannot be known from source alone.

- The tray now rechecks every 15 seconds and, when it detects the agent stopped or unloaded, starts a **quiet, throttled recovery** at most once every five minutes. Recovery re-enables, bootstraps and kickstarts **com.taptether.agent only** as necessary. Failed recovery does not trigger alerts, splash screens, installers, pairing prompts, or a rapid restart loop.
- Ordinary launchd KeepAlive remains enabled for user login and process crashes. Both routine and status-triggered recovery keep independently signed **Input Core** and **Screen Core** processes untouched.
- **Stop TapTether** now persists an explicit per-user stop marker and unloads only the remote agent. The tray will not override the user's deliberate Stop, even after relaunch. **Start TapTether** clears the marker. An explicit **Install / Repair** also resumes agent autostart.
- The tray shows actual launchd state after a manual button action, rather than replacing it with a temporary generic status message.
- **Settings → Agent diagnostics** distinguishes an intentionally stopped agent from a stopped or unloaded LaunchAgent, and reports the last exit code without exposing pairing tokens or raw logs.
- Offline regression tests mock launchctl to exercise agent restart after unload, no repeated restart of a healthy agent, an intentional Stop, and strict core isolation. They run in GitHub Actions.

**Limitation:** If the agent repeatedly crashes due to a bind failure, corrupted credentials or OS restrictions, bounded recovery cannot fix the underlying process error. Obtain the Mac's existing privacy-safe Agent diagnostics to investigate. No changes are made to signing, the macOS protected core executables, or pairing.
