import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@available(iOS 18.0, *)
private enum TVControlStyle {
    static let background = Color(red: 0.045, green: 0.092, blue: 0.145)
    static let panel = Color(red: 0.094, green: 0.171, blue: 0.235)
    static let accent = Color(red: 0.31, green: 0.89, blue: 0.88)
}

@available(iOS 18.0, *)
private struct TVActionButton: View {
    let target: TapTetherControlTarget
    let symbol: String
    let title: String
    var compact = false
    var wide = false

    var body: some View {
        Button(intent: TapTetherTVActionIntent(target: target)) {
            VStack(spacing: wide ? 2 : compact ? 1 : 4) {
                Image(systemName: symbol)
                    .font(.system(size: wide ? 17 : compact ? 15 : 19,
                                  weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: wide ? 19 : compact ? 17 : 23)
                Text(title)
                    .font(.system(size: wide ? 10 : compact ? 8.5 : 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: wide ? 44 : compact ? 38 : 56)
            .background(
                RoundedRectangle(cornerRadius: wide ? 12 : compact ? 10 : 14, style: .continuous)
                    .fill(TVControlStyle.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: wide ? 12 : compact ? 10 : 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.11), lineWidth: 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

@available(iOS 18.0, *)
private struct TVQuickButtons: View {
    var compact = false
    var wide = false

    var body: some View {
        HStack(spacing: wide ? 3 : 5) {
            TVActionButton(target: .power, symbol: "power", title: "Power",
                           compact: compact, wide: wide)
            TVActionButton(target: .volumeDown, symbol: "speaker.minus.fill",
                           title: "Vol −", compact: compact, wide: wide)
            TVActionButton(target: .mute, symbol: "speaker.slash.fill",
                           title: "Mute", compact: compact, wide: wide)
            TVActionButton(target: .volumeUp, symbol: "speaker.plus.fill",
                           title: "Vol +", compact: compact, wide: wide)
            TVActionButton(target: .home, symbol: "house.fill",
                           title: "Home", compact: compact, wide: wide)
        }
    }
}

@available(iOS 18.0, *)
private struct TVAppShortcuts: View {
    var compact = false
    var wide = false

    var body: some View {
        HStack(spacing: wide ? 3 : 5) {
            TVActionButton(target: .netflix, symbol: "play.rectangle.fill",
                           title: "Netflix", compact: compact, wide: wide)
            TVActionButton(target: .youtube, symbol: "play.tv.fill",
                           title: "YouTube", compact: compact, wide: wide)
            TVActionButton(target: .prime, symbol: "play.square.stack.fill",
                           title: "Prime", compact: compact, wide: wide)
            TVActionButton(target: .appleTV, symbol: "appletv.fill",
                           title: "Apple TV", compact: compact, wide: wide)
            TVActionButton(target: .playPause, symbol: "playpause.fill",
                           title: "Play/Pause", compact: compact, wide: wide)
        }
    }
}

@available(iOS 18.0, *)
struct TapTetherTVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TapTetherTVActivityAttributes.self) { context in
            VStack(alignment: .leading,
                   spacing: context.state.layout == "wide" ? 3 : 4) {
                HStack(spacing: 5) {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TVControlStyle.accent)
                    Text("TAPTETHER")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(TVControlStyle.accent)
                    Spacer()
                    Circle()
                        .fill(context.state.connected
                              ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(context.state.connected ? "Connected" : "Standby")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(context.state.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                TVQuickButtons(compact: true,
                               wide: context.state.layout == "wide")
                TVAppShortcuts(compact: true,
                               wide: context.state.layout == "wide")
            }
            // Keep the full Lock Screen Live Activity within iOS's compact
            // vertical budget. Oversize content is clipped at both ends.
            .padding(.horizontal, context.state.layout == "wide" ? 3 : 10)
            .padding(.vertical, context.state.layout == "wide" ? 5 : 8)
            .activityBackgroundTint(TVControlStyle.background)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("TapTether", systemImage: "tv.fill")
                        .font(.caption.bold())
                        .foregroundStyle(TVControlStyle.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(context.state.connected ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(context.state.connected ? "On" : "Standby")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        TVQuickButtons(compact: true)
                        TVAppShortcuts(compact: true)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "tv.fill")
                    .foregroundStyle(TVControlStyle.accent)
            } compactTrailing: {
                Image(systemName: "house.fill")
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "tv.fill")
                    .foregroundStyle(TVControlStyle.accent)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

@available(iOS 18.0, *)
private struct RemoteOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.remote") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .home)) {
                Label("TV Home", systemImage: "house.fill")
            }
        }
        .displayName("TapTether TV Home")
        .description("Open the TV home screen without launching TapTether")
    }
}

@available(iOS 18.0, *)
private struct RemotePowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.power") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .power)) {
                Label("TV Power", systemImage: "power")
            }
        }
        .displayName("TapTether TV Power")
        .description("Power on or off the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct RemoteMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.mute") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .mute)) {
                Label("TV Mute", systemImage: "speaker.slash.fill")
            }
        }
        .displayName("TapTether TV Mute")
        .description("Mute or unmute the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct RemoteUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.volumeup") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .volumeUp)) {
                Label("TV Volume Up", systemImage: "speaker.plus.fill")
            }
        }
        .displayName("TapTether TV Volume +")
        .description("Increase LG TV volume")
    }
}

@available(iOS 18.0, *)
private struct RemoteDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.volumedown") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .volumeDown)) {
                Label("TV Volume Down", systemImage: "speaker.minus.fill")
            }
        }
        .displayName("TapTether TV Volume −")
        .description("Decrease LG TV volume")
    }
}

@available(iOS 18.0, *)
private struct TVNetflixControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.netflix") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .netflix)) {
                Label("Netflix", systemImage: "play.rectangle.fill")
            }
        }
        .displayName("TapTether Netflix")
        .description("Launch Netflix on the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct TVYouTubeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.youtube") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .youtube)) {
                Label("YouTube", systemImage: "play.tv.fill")
            }
        }
        .displayName("TapTether YouTube")
        .description("Launch YouTube on the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct TVPrimeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.prime") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .prime)) {
                Label("Prime Video", systemImage: "play.square.stack.fill")
            }
        }
        .displayName("TapTether Prime Video")
        .description("Launch Prime Video on the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct TVAppleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.appletv") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .appleTV)) {
                Label("Apple TV", systemImage: "appletv.fill")
            }
        }
        .displayName("TapTether Apple TV")
        .description("Launch Apple TV on the selected LG TV")
    }
}

@available(iOS 18.0, *)
private struct TVPlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.playpause") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .playPause)) {
                Label("TV Play/Pause", systemImage: "playpause.fill")
            }
        }
        .displayName("TapTether TV Play/Pause")
        .description("Pause or resume TV playback without opening TapTether")
    }
}

@available(iOS 18.0, *)
private struct TVBackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.back") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .back)) {
                Label("TV Back", systemImage: "arrow.uturn.backward")
            }
        }
        .displayName("TapTether TV Back")
        .description("Go back on the selected LG TV without opening TapTether")
    }
}

@available(iOS 18.0, *)
private struct TVSelectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.taptether.control.ok") {
            ControlWidgetButton(action: TapTetherTVActionIntent(target: .ok)) {
                Label("TV OK", systemImage: "checkmark.circle.fill")
            }
        }
        .displayName("TapTether TV OK")
        .description("Select an item on the paired LG TV without opening TapTether")
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
        TVNetflixControl()
        TVYouTubeControl()
        TVPrimeControl()
        TVAppleControl()
        TVPlayPauseControl()
        TVBackControl()
        TVSelectControl()
    }
}
