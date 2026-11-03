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
for action in (".netflix", ".youtube", ".prime", ".appleTV", ".apps"):
    assert "target: " + action in widgets
for control in ("RemoteOpenControl", "RemotePowerControl", "RemoteMuteControl",
                "RemoteUpControl", "RemoteDownControl",
                "TVBackControl", "TVSelectControl"):
    assert f"struct {control}: ControlWidget" in widgets
assert "DynamicIslandExpandedRegion(.bottom)" in widgets
assert "WidgetBundle" in widgets
assert "Activity.request(" in runner
assert "UIApplication.didBecomeActiveNotification" in runner
assert "group.com.taptether.taptether.controls" in shared
assert "com.apple.security.application-groups" in staging
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
