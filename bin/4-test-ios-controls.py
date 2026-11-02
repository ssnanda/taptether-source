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

assert "struct TapTetherTVActivityAttributes: ActivityAttributes" in shared
assert "struct TapTetherOpenRemoteIntent: OpenIntent" in shared
assert "openAppWhenRun" not in shared.split("struct TapTetherOpenRemoteIntent: OpenIntent", 1)[1]
assert "ControlWidgetButton(action:" in widgets
assert "ActivityConfiguration(for: TapTetherTVActivityAttributes.self)" in widgets
for control in ("RemoteOpenControl", "RemotePowerControl", "RemoteMuteControl",
                "RemoteUpControl", "RemoteDownControl"):
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
