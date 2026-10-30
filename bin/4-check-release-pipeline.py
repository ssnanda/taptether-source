#!/usr/bin/env python3
"""Static checks for TapTether's explicitly requested full-release workflow."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / ".github" / "workflows"
workflow_files = sorted(folder.glob("*.yml")) + sorted(folder.glob("*.yaml"))
assert len(workflow_files) == 1 and workflow_files[0].name == "taptether.yml", (
    "Expected exactly one maintained Actions workflow: taptether.yml"
)

workflow = workflow_files[0].read_text(encoding="utf-8")
publisher = (ROOT / "bin" / "6-tt-publish-latest.sh").read_text(encoding="utf-8")
stage = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text(encoding="utf-8")

assert "workflow_dispatch:" in workflow
assert "schedule:" in workflow
assert "task:" in workflow
assert all(f"- {mode}" in workflow for mode in ("release", "build", "validate", "agent-ubuntu", "agent-macos", "agent-windows"))
assert "          - cleanup" in workflow
assert "  push:\n    branches: [main, fix/v0.6-remote-scan-mac-details]" in workflow, (
    "Explicit agent-only push updates; full releases require workflow dispatch"
)
assert "github.ref == 'refs/heads/main'" in workflow
assert "    paths:\n      - VERSION" not in workflow, (
    "VERSION pushes must not publish automatically before iPhone installation"
)
assert "if: ${{ inputs.task == 'release' || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[publish 201]')) }}" in workflow
assert "- 'app/lib/xbox_*.dart'" in workflow
assert "- '.github/workflows/taptether.yml'" in workflow
assert "[build xbox]" in workflow
assert "[build ipa]" in workflow
assert "if: ${{ (github.event_name == 'workflow_dispatch' && (inputs.task == 'release' || inputs.task == 'build')) || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[build xbox]')) || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[build ipa]')) || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[publish 201]')) }}" in workflow

assert "  validate:" in workflow
assert "  build-ubuntu:" in workflow
assert "    needs: validate" in workflow
assert "github.event_name == 'push' || inputs.task == 'release' || inputs.task == 'build'" not in workflow
assert "  build-and-publish:" in workflow
assert "    needs: [build-ubuntu, build-windows]" in workflow
assert "  build-windows:" in workflow
assert "run: bash bin/2c-tt-windows.sh" in workflow
# All scripts invoked directly by a release build must have an executable
# Git mode; bash-invoked scripts are permitted to be non-executable.
for script in (
    "bin/2b-tt-agent.sh",
    "bin/2b-tt-ubuntu.sh",
    "bin/2b-tt-deb.sh",
    "bin/2b-tt-macos.sh",
    "bin/2e-tt-stage-mobile-agents.sh",
):
    assert (ROOT / script).stat().st_mode & 0o111, (
        f"{script} must be executable in Git; check chmod +x"
    )
ubuntu_builder = (ROOT / "bin" / "2b-tt-ubuntu.sh").read_text(encoding="utf-8")
assert 'bash "$ROOT/bin/2b-tt-deb.sh"' in ubuntu_builder, (
    "Invoke the Debian package builder via bash to avoid exit 126"
)

provisioner = (ROOT / "app" / "lib" / "ssh_provisioner.dart").read_text(encoding="utf-8")
deb_builder = (ROOT / "bin" / "2b-tt-deb.sh").read_text(encoding="utf-8")
assert 'dpkg --install' in provisioner, (
    "Install private-mode staged Ubuntu packages directly with dpkg"
)
assert 'apt-get install -y --no-install-recommends' not in provisioner, (
    "Never hand inaccessible private-mode staged packages to _apt"
)
assert "'Suggests: xdotool" in deb_builder
assert "'Depends: xdotool" not in deb_builder

assert "Verify Ubuntu packages with native dpkg" in workflow
assert 'sudo dpkg --install "dist/ubuntu/taptether-agent_' in workflow
assert "dpkg-deb --info" in workflow

assert "python3 bin/4-test-deb-packaging.py" in workflow, (
    "Run offline Debian payload regression test before expensive agent builds"
)
assert "python3 bin/4-test-macos-uninstall.py" in workflow, (
    "Run safe macOS uninstall regression test before builds"
)
assert "python3 bin/4-test-macos-agent-recovery.py" in workflow, (
    "Verify macOS LaunchAgent self-healing respects manual Stop and protected cores"
)
assert "python3 bin/4-test-macos-input-core.py" in workflow
assert "run: bash bin/2b-tt-ubuntu.sh" in workflow
assert "run: bash bin/2b-tt-macos.sh" in workflow
# Foreground iOS notifications must retain a native notification-center
# delegate; a successful show() call alone does not guarantee a banner.
native_notifications = (ROOT / "bin" / "ios" / "AppDelegate.swift").read_text()
fridge_notifications = (ROOT / "app" / "lib" / "fridge_alerts.dart").read_text()
mobile_dashboard = (ROOT / "app" / "lib" / "main.dart").read_text()
ios_staging = (ROOT / "bin" / "2f-tt-ios-cloud-backup.sh").read_text()
assert "import UserNotifications" in native_notifications
assert "UNUserNotificationCenter.current().delegate = self" in native_notifications
assert "cp \"$ROOT/bin/ios/AppDelegate.swift\" \"$IOS/AppDelegate.swift\"" in ios_staging
assert "presentBanner: true" in fridge_notifications
assert "presentList: true" in fridge_notifications
assert "showTestNotification()" in mobile_dashboard
assert "Notification failed: $error" in mobile_dashboard
assert "taptether/background-refresh" in native_notifications
assert "BGTaskSchedulerPermittedIdentifiers" in (
    ROOT / "bin" / "2h-tt-fridge-background.sh").read_text()
assert "recordBackgroundWake" in fridge_notifications
assert "recordBackgroundResult" in fridge_notifications
assert "Background monitor status" in mobile_dashboard
xbox_ui = (ROOT / "app" / "lib" / "xbox_remote_screen.dart").read_text()
assert "Check Xbox IP" in xbox_ui
assert "Scan entire local network" in xbox_ui
assert "Xbox app preferences" not in xbox_ui

assert "run: bash bin/2a-tt-ipa.sh --no-publish" in workflow
assert "run: bash bin/2a-tt-apk.sh --no-publish" in workflow
assert "run: bash bin/6-tt-publish-latest.sh" in workflow
assert "if: ${{ inputs.task == 'release' || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[publish 201]')) }}" in workflow
assert "if: ${{ inputs.task == 'build' || (github.event_name == 'push' && contains(github.event.head_commit.message, '[build xbox]')) || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[build ipa]')) }}" in workflow
assert workflow.count("if: ${{ inputs.task == 'release' || (github.event_name == 'push' && github.ref == 'refs/heads/main' && contains(github.event.head_commit.message, '[publish 201]')) }}") >= 2
assert "TapTether-complete-build-" in workflow
assert "retention-days: 1" in workflow

assert "name: TapTether-Ubuntu-installers" in workflow
assert "actions/download-artifact@" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS: '1'" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS:-0" in stage
assert 'gh release create "$TAG"' in publisher
assert 'git show origin/main:VERSION' in publisher
assert 'if [[ "$remote_version" != "$VERSION" ]]; then' in publisher
assert 'git worktree add' not in publisher
assert 'git push origin' not in publisher
assert '--target main' in publisher
assert 'TAPTETHER_PUBLIC_RELEASE_TOKEN' in workflow
assert 'gh release delete "$platform-current"' in publisher
assert 'repos/$REPO/contents/altstore.json' in publisher
assert 'VERSION_TAG=' not in publisher
assert 'Source commit:' not in publisher
assert 'Build workflow:' not in publisher
assert 'expected_assets=(' in publisher
assert 'Refusing older or duplicate release' in publisher
assert "release-v0.6.2-request" not in workflow
iphone_installer = (ROOT / "bin" / "3-install-iphone.sh").read_text()
assert "    --publish) PUBLISH=1; shift ;;" in iphone_installer
assert "gh workflow run taptether.yml -R ssnanda/taptether-source --ref main -f task=release" in iphone_installer
assert iphone_installer.index("banner 'INSTALLATION COMPLETE'") < iphone_installer.index("if (( PUBLISH )); then", iphone_installer.index("banner 'INSTALLATION COMPLETE'"))
assert "gh release upload" not in iphone_installer  # Never publish personal signing credentials

assert 'python3 bin/4-test-agent-release-feeds.py' in workflow
assert 'python3 bin/4-guard-release-sync.py' in publisher
assert "  agent-only-validate:" in workflow
assert "  agent-only-ubuntu:" in workflow
assert "  agent-only-macos:" in workflow
assert "  agent-only-windows:" in workflow
assert "The [publish 201] push trigger is valid for 0.8.40+201 only." in workflow
assert "  cleanup-history:" in workflow
assert "    needs: build-and-publish" in workflow
assert "    if: ${{ always() && (github.event_name == 'schedule' || inputs.task == 'cleanup'" in workflow
assert "always() && (github.event_name == 'schedule'" in workflow
assert "inputs.task == 'cleanup'" in workflow
assert "inputs.task != 'cleanup'" in workflow
assert "contains(github.event.head_commit.message, '[cleanup actions]')" in workflow
assert "needs.build-and-publish.result == 'success'" in workflow

# Regression guards: the Mac Finder installer must report and recover from
# launchd failures without copying raw pairing details or logs.
mac_setup = (ROOT / "bin" / "4-macos-agent-setup.sh").read_text(encoding="utf-8")
mac_tray = (ROOT / "desktop" / "macos" / "TapTetherTray.swift").read_text(
    encoding="utf-8")
assert "diagnostics) diagnostics" in mac_setup
assert 'uninstall) uninstall_agent "${2:-}"' in mac_setup
assert 'trash_path "$TRAY_BUNDLE"' in mac_setup
assert 'trash_path "$CONF"' in mac_setup
assert 'codesign --verify "$APP"' in mac_setup
assert "Repair Accessibility…" in mac_tray
assert "Uninstall TapTether…" in mac_tray
assert 'add(menu, "Quit TapTether", #selector(quitMenu))' in mac_tray
assert 'task.arguments = [controller, "stop"]' in mac_tray
assert 'coreRemaining' in mac_tray
assert "Quit menu (agent stays running)" not in mac_tray
assert 'erase ? "--erase-pairing" : "--keep-pairing"' in mac_tray
assert "restart) start_agent" in mac_setup
assert "launchctl bootstrap" in mac_setup
assert "Privacy: no passwords, pairing tokens" in mac_setup
# Regression: a running macOS updater was truncated by the installer using
# cp directly over its live script. Require same-directory rename instead.
assert "atomic_install_helper" in mac_setup
assert 'mv -f "$staged" "$destination"' in mac_setup
assert 'atomic_install_helper "$0" "$CTL" 755' in mac_setup
assert 'atomic_install_helper "$SELF/taptether-agent-update-mac" "$UPDATER" 700' in mac_setup
assert 'then cp "$0" "$CTL"' not in mac_setup
assert "  pairing\n}" not in mac_setup  # no private token printed on updates
assert "Copy diagnostics" in mac_tray
assert "Open Accessibility settings" in mac_tray

# All desktop tray menus must perform updates, not merely display a CLI hint.
ubuntu_tray = (ROOT / "desktop" / "ubuntu" / "taptether_tray.py").read_text(
    encoding="utf-8")
win_tray = (ROOT / "desktop" / "windows" / "TapTetherTray.ps1").read_text(
    encoding="utf-8")
win_installer = (ROOT / "desktop" / "windows" / "Install-TapTether.ps1").read_text(
    encoding="utf-8")
win_updater = (ROOT / "desktop" / "windows" / "Update-TapTether.ps1").read_text(
    encoding="utf-8")
assert 'title: "Check for Updates…"' in mac_tray
assert 'task.arguments = [controller, "update"]' in mac_tray
assert 'task.standardOutput = FileHandle.nullDevice' in mac_tray
assert "update_from_tray" in ubuntu_tray
assert 'add_menu_item(m, "Check for Updates…", update_from_tray)' in ubuntu_tray
assert 'taptether-update.service' in ubuntu_tray
assert "Check for Updates..." in win_tray
assert "Update-TapTether.ps1" in win_tray
assert "TapTetherTray.ps1" in win_installer and "TapTetherTray.ps1" in win_updater
assert "TapTetherTray.ps1" in workflow
assert "PowerShell syntax" in workflow
# Every desktop has one dynamic Start/Stop, Pair, Update, Settings and Quit.
assert 'startStopItem?.title = isRunning ? "Stop TapTether" : "Start TapTether"' in mac_tray
assert 'add(menu, "Pair Device", #selector(pairingInstructions))' in mac_tray
assert 'let settingsMenu = NSMenu(title: "Settings")' in mac_tray
assert 'add(menu, "Quit TapTether", #selector(quitMenu))' in mac_tray
assert 'start_stop.set_label("Stop TapTether" if active else "Start TapTether")' in ubuntu_tray
assert 'add_menu_item(m, "Pair Device", pair_device)' in ubuntu_tray
assert 'settings_item.set_submenu(settings)' in ubuntu_tray
assert 'add_menu_item(m, "Quit TapTether", quit_taptether)' in ubuntu_tray
assert 'if service_control("stop"):' in ubuntu_tray
assert '$startStopItem.Text = if ($isRunning)' in win_tray
assert "$pairingItem = $menu.Items.Add('Pair Device')" in win_tray
assert "$settingsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Settings')" in win_tray
assert "$quitItem = $menu.Items.Add('Quit TapTether')" in win_tray
assert 'if (Stop-ManagedAgent)' in win_tray

# My Devices probes saved hosts on the current subnet. Any offline pairing triggers passive recovery
# uses one Wi-Fi UDP discovery plus a throttled bounded agent-port-only
# TCP fallback. An open port never changes identity without saved TLS auth.
recovery = (ROOT / "app" / "lib" / "device_recovery.dart").read_text(
    encoding="utf-8")
mobile = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert "probeAgentControlPorts" in recovery
assert "Socket.connect(ip, 48321" in recovery
heartbeat = mobile.split(
    "  Future<void> _refreshHeartbeats() async {", 1)[1].split(
    "  // Recover each offline saved pairing quietly", 1)[0]
assert "_probeSavedDevice(device, phone)" in heartbeat
assert "probeAgentControlPorts(" not in heartbeat
assert "findNearbyDevices(" not in heartbeat
assert "unawaited(_recoverSavedDevices())" in heartbeat
recovery_call = mobile.split("  Future<void> _recoverSavedDevices(", 1)[1].split(
    "  Future<void> _labelCurrentNetwork()", 1)[0]
assert "broadcastOnly: true" in recovery_call
assert "lanBroadcastAddress(network)" in recovery_call
assert "scanPrivate24(" not in recovery_call
assert "probeAgentControlPorts(" in recovery_call
assert "parallelism: 24" in recovery_call
assert "maxHits: 16" in recovery_call
assert "Duration(minutes: 10)" in recovery_call
assert "_reconcileScannedAgent(address, passive: true)" in recovery_call

# Explicit Scan IPs/Discover must reconcile saved computers immediately.
# Background agents never need to poll the phone.
scan_screen = (ROOT / "app" / "lib" / "lan_scan_screen.dart").read_text(encoding="utf-8")
scan_logic = (ROOT / "app" / "lib" / "lan_scan.dart").read_text(encoding="utf-8")
mobile = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert "verifyPairedAgent: _reconcileScannedAgent" in mobile
assert "Future<String?> _reconcileScannedAgent" in mobile
assert "await _pingSavedDevice(saved, phone, atHost: ip)" in mobile
assert "await deviceStore.upsert(verified)" in mobile
assert "_reconcileDiscoveredAgents(result)" in mobile
assert "onAgentFound: _showAgentCandidate" in scan_screen
assert "await Future.wait(_pendingVerifications)" in scan_screen
assert "onAgentFound?.call(candidate)" in scan_logic

# Guard against regressing the broken 0.6.7 remote class and F-key parser.
remote = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert remote.count("Widget _connectedControls()") == 1
assert remote.count("Widget build(BuildContext context)") == 2
assert "if (RegExp(r'^f(?:[1-9]|1[0-2])$').hasMatch(id)) return id;" in remote
assert "}).hasMatch(id)) return id;" not in remote

# Presentation mode shares only authenticated LAN keyboard commands; no
# screen-reading or note capture is part of the 0.6.9 feature.
presentation = (ROOT / "app" / "lib" / "presentation_mode.dart").read_text(
    encoding="utf-8")
layout = (ROOT / "app" / "lib" / "remote_layout_settings.dart").read_text(
    encoding="utf-8")
assert 'Widget _landscapeImmersive()' in remote
assert "ValueKey('immersive-controls-toggle')" in remote
assert "ValueKey('immersive-controls-dock')" in remote
assert 'MediaQuery.orientationOf(context) == Orientation.landscape' in remote
assert 'Widget _presentationView(bool landscape)' in remote
assert '_compactModeSwitcher()' in remote
compact_bar = (ROOT / 'app' / 'lib' / 'remote_mode_bar.dart').read_text(
    encoding='utf-8')
assert "ValueKey('one-row-remote-navigation')" in compact_bar
assert "ValueKey('screen-view-mode-switcher')" in compact_bar
assert "'presentation'" in compact_bar and "'media'" in compact_bar
assert 'PresentationShortcuts.start' in presentation
assert "static const next = 'Right';" in presentation
assert "static const previous = 'Left';" in presentation
assert "static const stop = 'Escape';" in presentation
assert "static const blankToggle = 'b';" in presentation
assert "this.presentationMode = false" in layout
assert "this.presentationApp = 'powerPoint'" in layout

# Dashboard/discovery release guards. A previously hard-coded home subnet
# must not silently return through either the scanner or device installer.
lan = (ROOT / "app" / "lib" / "lan_scan.dart").read_text(encoding="utf-8")
scan_screen = (ROOT / "app" / "lib" / "lan_scan_screen.dart").read_text(encoding="utf-8")
installer = (ROOT / "app" / "lib" / "install_agent_screen.dart").read_text(encoding="utf-8")
devices = (ROOT / "app" / "lib" / "device_visibility.dart").read_text(encoding="utf-8")
agent_main = (ROOT / "agent" / "cmd" / "taptether-agent" / "main.go").read_text(
    encoding="utf-8")
assert "rangeFromWifi(" in lan and "getWifiSubmask()" in lan
assert "lanRangeContains(" in lan
assert "_network!.scanPrefixes" in scan_screen
assert "InstallAgentScreen" in installer and "Computer OS" in installer
assert "knownPlatform" in installer and "Download Windows agent" in installer
assert "visibleSavedDevices(" in devices and "showOffline" in devices
assert "Timer.periodic(const Duration(seconds: 60)" in remote
assert "RefreshHeartbeats" not in remote or "_refreshHeartbeats()" in remote
assert "'hostname'" not in agent_main or '"hostname": hostname' in agent_main
assert '"platform": runtime.GOOS' in agent_main
assert "deviceLocations" in remote and "NetworkLocationStore" in remote

# macOS and Ubuntu install/update are performed from the phone using
# checksum-verified same-build assets and per-host trusted SSH identities.
mac_ssh = (ROOT / "app" / "lib" / "macos_ssh_provisioner.dart").read_text(
    encoding="utf-8")
ssh_ui = (ROOT / "app" / "lib" / "ubuntu_install_screen.dart").read_text(
    encoding="utf-8")
device_manager = (ROOT / "app" / "lib" / "device_manager_screen.dart").read_text(
    encoding="utf-8")
assert "MacSshProvisioner" in mac_ssh
assert "sha256.convert(archive)" in mac_ssh
assert "rememberAuthenticated(input.host" in mac_ssh
assert "updateOnly" in mac_ssh and "updateOnly" in provisioner
assert "macosPairingFromOutput" in mac_ssh
assert "MacSshProvisioner.install" in ssh_ui
assert "UbuntuSshProvisioner.install" in ssh_ui
assert "Update Agent" in device_manager
assert "onUpdate: updateSavedAgent" in remote
assert "requestUpdate()" in remote
assert "updateSavedAgent" in remote
assert "macos" in stage and 'TapTetherAgent-macos-' in stage
mac_test = (ROOT / "app" / "test" /
    "macos_ssh_provisioner_test.dart").read_text(encoding="utf-8")
assert "macosPairingFromOutput" in mac_test
assert "macosArchiveArchitecture" in mac_test
assert "mergeDiscoveredAgents(" in lan
assert "checkPrivateLanIp(" in lan
assert "device.scanSubtitle" in scan_screen
assert "Check a specific device" in scan_screen


print("PASS: one Actions workflow, explicit full release after iPhone install, manual cleanup")
print("PASS: validate -> Ubuntu/Windows/macOS agents -> IPA/APK -> publish")
print("PASS: binary-only public rolling releases; no historical tags")
