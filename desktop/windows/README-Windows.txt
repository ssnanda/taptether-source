TapTether Windows Agent (0.6 test build)
========================================
1. Extract this ZIP into a folder on your own Windows computer.
2. Double-click Install-TapTether.cmd.
3. Accept the narrowly-scoped Private LAN firewall UAC prompt if offered.
4. Double-click Show-Pairing.cmd. Keep its token and fingerprint private.
5. In TapTether on your phone: Pair computer, enter its IP, token and TLS fingerprint.
6. Use your phone to test mouse movement, clicks, scrolling and keyboard shortcuts.
7. Remote shutdown is checked ON by default. Double-click Configure-Shutdown.cmd
   to uncheck it at any time, then reconnect the phone to refresh the button.

Works in an interactive signed-in Windows user session; no SSH needed.
Does not control UAC secure desktops, lock screens, or elevated applications.
No installer signature/notarization is included in the test build.
Agent starts on sign-in through HKCU Run; it is not a Windows service.
Only PRIVATE profile firewall ports 48321/TCP and 48322/UDP are opened when approved.

To stop: use Windows Task Manager and end TapTetherAgent.exe.
To uninstall: remove HKCU\Software\Microsoft\Windows\CurrentVersion\Run
value TapTetherAgent, remove %LOCALAPPDATA%\TapTether, and remove
the two TapTether Private LAN firewall rules (administrator required).
Pairing identity is stored under %APPDATA%\taptether.
Do not delete that identity folder unless you want to revoke this local installation.
