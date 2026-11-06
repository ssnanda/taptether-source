#!/usr/bin/env python3
"""Guard Control Center, native extension and LG session handoff wiring."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
shared = (root / "bin/ios/TapTetherControlsShared.swift").read_text()
widgets = (root / "bin/ios/TapTetherControlWidgets.swift").read_text()
runner = (root / "bin/ios/TapTetherControlsRunner.swift").read_text()
staging = (root / "bin/2i-tt-ios-controls.sh").read_text()
ipa = (root / "bin/2a-tt-ipa.sh").read_text()
app = (root / "app/lib/main.dart").read_text()
lg = (root / "app/lib/lg_webos_screen.dart").read_text()
quick = (root / "app/lib/tv_quick_controls.dart").read_text()

native = (root / "bin/ios/TapTetherLgRemoteNative.swift").read_text()
assert "struct TapTetherTVActivityAttributes: ActivityAttributes" in shared
assert "struct TapTetherTVActionIntent: LiveActivityIntent" in shared
assert "static var supportedModes: IntentModes { .background }" in shared
assert "struct TapTetherOpenRemoteIntent: OpenIntent" not in shared
assert "openAppWhenRun" not in shared
assert "SecItemAdd" in shared and "SecItemCopyMatching" in shared
assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in shared
assert "URLSessionWebSocketTask" in native
assert "SHA256.hash(data: der)" in native
assert "identityMismatch" in native
assert "ssap://com.webos.applicationManager/listLaunchPoints" in native
assert "ssap://com.webos.applicationManager/launch" in native
assert "ssap://audio/volumeUp" in native
assert "ssap://audio/setMute" in native
assert "ssap://system/turnOff" in native
assert "type:button" in native and "name:" in native
assert 'button: "HOME"' in native
assert "client-key" in native
assert "TapTetherLgRemoteNative.swift" in staging
assert "clientKey" in runner and "TapTetherTVKeychain.save" in runner
assert "clientKey" in quick and "tlsPin" in quick
assert "ControlWidgetButton(action: TapTetherTVActionIntent" in widgets
assert "Button(intent: TapTetherTVActionIntent" in widgets
assert "ActivityConfiguration(for: TapTetherTVActivityAttributes.self)" in widgets
assert "activityBackgroundTint(TVControlStyle.background)" in widgets
assert "TVAppShortcuts" in widgets
assert 'target: .playPause' in widgets
assert 'TVPlayPauseControl()' in widgets
assert 'TVAppsControl' not in widgets
assert 'target: .apps' not in widgets
assert 'case .playPause:' in native
assert 'ssap://media.controls/play' in native
assert 'ssap://media.controls/pause' in native
assert 'getForegroundAppInfo' in native
assert 'togglePlayback' in native
assert 'TV Play/Pause' in shared
assert 'case netflix, youtube, prime, appleTV, playPause' in shared
assert 'Play/Pause' in (root / "app/lib/tv_controls_settings_screen.dart").read_text()
# Both rows must fit inside the system-imposed Lock Screen activity height.
assert 'TVQuickButtons(compact: true,' in widgets
assert 'TVAppShortcuts(compact: true,' in widgets
assert '.frame(height: wide ? 44 : compact ? 38 : 56)' in widgets
assert 'context.state.layout == "wide" ? 3 : 10' in widgets
assert 'context.state.layout == "wide" ? 5 : 8' in widgets
assert 'var layout: String?' in shared
assert 'lockLayout' in shared and 'layoutKey' in shared
assert 'case "setLayout":' in runner and 'case "getLayout":' in runner
assert 'getLockScreenLayout' in quick and 'setLockScreenLayout' in quick
assert 'TVBackControl()' in widgets and 'TVSelectControl()' in widgets
assert 'case .back:' in native and 'case .ok:' in native
assert 'sendPointerButton' in native and 'button: "BACK"' in native
assert 'tv_controls_settings_screen.dart' in app
assert 'drawer-tv-quick-controls' in app
for action in (".netflix", ".youtube", ".prime", ".appleTV", ".playPause"):
    assert "target: " + action in widgets
for control in ("RemoteOpenControl", "RemotePowerControl", "RemoteMuteControl",
                "RemoteUpControl", "RemoteDownControl",
                "TVBackControl", "TVSelectControl"):
    assert f"struct {control}: ControlWidget" in widgets
assert "DynamicIslandExpandedRegion(.bottom)" in widgets
assert "WidgetBundle" in widgets
assert "Activity.request(" in runner
assert "NWPathMonitor(requiredInterfaceType: .wifi)" in runner
assert "TapTetherTVActivityPolicy.allowed" in runner
assert "TapTetherTVActivityExpiry.schedule" in runner
assert "TapTetherTVActivityExpiry.dismissExpired" in runner
assert "dismissalPolicy: .immediate" in runner
assert "15 * 60" in shared and "hour >= 9 && hour < 21" in shared
assert "expiresAt: Date?" in shared
assert "staleDate: deadline" in runner
assert 'tv-controls-expire' in staging
assert "TapTetherTVActivityExpiry.register()" in (root / "bin/ios/AppDelegate.swift").read_text()
assert "getPowerState" in quick
assert "confirmedPowerOn" in quick
assert "tvPowerOn" in quick and "tvPowerOn" in runner
assert "_showQuickControlsIfOn" in lg
assert "userInitiated: userInitiated" in lg
assert "userInitiated: true" in lg
assert "'userInitiated': userInitiated" in quick
assert "else if userInitiated" in runner
assert "withTimeInterval: 60, repeats: true" in runner
assert "verifyActiveTVPower" in runner
assert "TapTetherLgRemoteNative.selectedTVIsOn" in runner
assert "static func selectedTVIsOn(host: String)" in native
assert "ssap://com.webos.service.tvpower/power/getPowerState" in native
assert "Activity.request(" not in runner.split("static func verifyActiveTVPower()", 1)[1]
assert "sendWakePacket" not in native.split("static func selectedTVIsOn(host: String)", 1)[1].split("private static func makeMessage", 1)[0]
assert "UIApplication.didBecomeActiveNotification" in runner
assert "group.com.taptether.taptether.controls" in shared
assert "com.apple.security.application-groups" in staging
assert "com.taptether.taptether.controls" in staging
assert "com.taptether.taptether.tv-controls-expire" in runner
assert "com.taptether.taptether.lg-controls" in shared
assert "--org com.taptether" in (root / ".github/workflows/taptether.yml").read_text()
assert "com.taptether.taptether.fridge-watch" in (root / "app/lib/fridge_alerts.dart").read_text()
assert "com.taptether.taptether.lg-tv-wake" in (root / "app/lib/lg_wake_recovery.dart").read_text()
assert '"developerName": "ITSpector LLC"' in (root / "bin/6-tt-generate-altstore.py").read_text()
# Same iOS bundle ID as 0.8.81+242: this is an in-place upgrade,
# not a second app. The brand/publisher is independent of bundle prefix.
altstore_gen = (root / "bin/6-tt-generate-altstore.py").read_text()
installer = (root / "bin/3-install-iphone.sh").read_text()
assert 'IOS_BUNDLE_ID = "com.taptether.taptether"' in altstore_gen
assert 'CONTROLS_BUNDLE_ID = "com.taptether.taptether.controls"' in altstore_gen
assert "com.taptether.taptether" in installer
assert "--org com.taptether" in installer
assert "config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.taptether.taptether'" in staging
assert 'com.taptether.taptether' in (root / "bin/2h-tt-fridge-background.sh").read_text()

assert "NSSupportsLiveActivities" in staging
assert "new_target(:app_extension" in staging
assert "Embed TapTether Controls" in staging
assert "bin/2i-tt-ios-controls.sh" in ipa
assert "TvQuickControls.instance.initialize();" in app
assert "TvQuickControls.instance.consumePending()" in app
assert "TvQuickControls.instance.select" in lg
assert "LgTvStore().read()" in quick
assert "LgWebOsClient(tv)" in quick
assert "LgWakeRecovery.instance.queue(tv)" in quick
assert "TvQuickControls.instance.select" in lg
assert "selected TV's address and label" in shared
# The only shared credential must be a Keychain item, not a UserDefaults key.
assert 'defaults.set(clientKey' not in runner
assert 'defaults.set(data["clientKey"]' not in runner
print("PASS native iOS TV controls, Live Activity, secure LG action handoff")

# Connection timings remain scoped to the selected LG TV and persist
# independent of the temporary widget/live-activity UI.
timing = (root / "app/lib/lg_connection_timing.dart").read_text()
screen = (root / "app/lib/lg_webos_screen.dart").read_text()
assert "class LgConnectionTimingStore" in timing
assert "pin:" in timing and "uuid:" in timing
assert "_recordPowerOn" in screen and "_recordFinding" in screen
assert "_recordFound" in screen and "_recordConnected" in screen
assert "lg-connection-timing" in screen
assert "Timer.periodic(const Duration(seconds: 1)" in screen
