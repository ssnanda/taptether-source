import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@available(iOS 18.0, *)
private struct TVQuickButtons: View {
    var body: some View {
        HStack(spacing: 14) {
            Button(intent: TapTetherPowerIntent()) {
                Image(systemName: "power")
            }.accessibilityLabel("TV power")
            Button(intent: TapTetherVolumeDownIntent()) {
                Image(systemName: "speaker.minus.fill")
            }.accessibilityLabel("Volume down")
            Button(intent: TapTetherMuteIntent()) {
                Image(systemName: "speaker.slash.fill")
            }.accessibilityLabel("Mute")
            Button(intent: TapTetherVolumeUpIntent()) {
                Image(systemName: "speaker.plus.fill")
            }.accessibilityLabel("Volume up")
            Button(intent: TapTetherOpenRemoteIntent()) {
                Image(systemName: "appletvremote.gen4.fill")
            }.accessibilityLabel("Open remote")
        }
        .buttonStyle(.bordered)
        .tint(.teal)
    }
}

@available(iOS 18.0, *)
struct TapTetherTVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TapTetherTVActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("TapTether", systemImage: "tv")
                        .font(.caption.bold())
                    Spacer()
                    Text(context.state.connected ? "Connected" : "Standby")
                        .font(.caption2)
                        .foregroundStyle(context.state.connected ? .green : .secondary)
                }
                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                TVQuickButtons()
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.90, green: 0.98, blue: 0.97))
            .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("TapTether", systemImage: "tv").font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.connected
                          ? "wifi" : "wifi.slash")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TVQuickButtons().padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "tv")
            } compactTrailing: {
                Image(systemName: "appletvremote.gen4.fill")
            } minimal: {
                Image(systemName: "tv")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

@available(iOS 18.0, *)
private struct RemoteOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.remote") {
            ControlWidgetButton(action: TapTetherOpenRemoteIntent()) {
                Label("TV Remote", systemImage: "appletvremote.gen4.fill")
            }
        }
        .displayName("TapTether TV Remote")
        .description("Open the last-used paired LG TV")
    }
}

@available(iOS 18.0, *)
private struct RemotePowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.power") {
            ControlWidgetButton(action: TapTetherPowerIntent()) {
                Label("TV Power", systemImage: "power")
            }
        }
        .displayName("TapTether TV Power")
        .description("Power on or off the last-used LG TV")
    }
}

@available(iOS 18.0, *)
private struct RemoteMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.mute") {
            ControlWidgetButton(action: TapTetherMuteIntent()) {
                Label("TV Mute", systemImage: "speaker.slash.fill")
            }
        }
        .displayName("TapTether TV Mute")
        .description("Mute or unmute the last-used LG TV")
    }
}

@available(iOS 18.0, *)
private struct RemoteUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.volumeup") {
            ControlWidgetButton(action: TapTetherVolumeUpIntent()) {
                Label("TV Volume Up", systemImage: "speaker.plus.fill")
            }
        }
        .displayName("TapTether TV Volume +")
        .description("Increase the last-used LG TV volume")
    }
}

@available(iOS 18.0, *)
private struct RemoteDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.volumedown") {
            ControlWidgetButton(action: TapTetherVolumeDownIntent()) {
                Label("TV Volume Down", systemImage: "speaker.minus.fill")
            }
        }
        .displayName("TapTether TV Volume −")
        .description("Decrease the last-used LG TV volume")
    }
}

@main
@available(iOS 18.0, *)
struct TapTetherControlWidgets: WidgetBundle {
    var body: some Widget {
        TapTetherTVLiveActivity()
        RemoteOpenControl()
        RemotePowerControl()
        RemoteMuteControl()
        RemoteUpControl()
        RemoteDownControl()
    }
}
