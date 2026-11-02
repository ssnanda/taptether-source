import Foundation
import AppIntents
import ActivityKit

/// The extension shares only a TV label, host and one pending action with
/// the unlocked Flutter app. Pairing secrets never leave the iOS Keychain.
enum TapTetherSharedTV {
    static let group = "group.com.taptether.taptether.controls"
    static let hostKey = "lastLgHost"
    static let nameKey = "lastLgName"
    static let actionKey = "pendingLgAction"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func request(_ action: String) {
        guard ["open", "power", "volumeUp", "volumeDown", "mute"].contains(action) else { return }
        defaults?.set(action, forKey: actionKey)
    }
}

@available(iOS 16.2, *)
struct TapTetherTVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var connected: Bool
    }
    var pairedHost: String
}

@available(iOS 18.0, *)
enum TapTetherControlTarget: String, AppEnum {
    case open
    case power
    case volumeUp
    case volumeDown
    case mute

    static var typeDisplayRepresentation = TypeDisplayRepresentation("TapTether TV action")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .open: DisplayRepresentation("Open remote"),
        .power: DisplayRepresentation("TV power"),
        .volumeUp: DisplayRepresentation("Volume up"),
        .volumeDown: DisplayRepresentation("Volume down"),
        .mute: DisplayRepresentation("Mute")
    ]
}

/// OpenIntent foregrounds the host app, requiring unlock when necessary.
/// A widget extension may not use the deprecated openAppWhenRun property.
@available(iOS 18.0, *)
struct TapTetherOpenRemoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "TapTether TV Remote"

    @Parameter(title: "TV action")
    var target: TapTetherControlTarget

    init() { target = .open }
    init(target: TapTetherControlTarget) { self.target = target }

    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request(target.rawValue)
        return .result()
    }
}
