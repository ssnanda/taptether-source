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
struct TapTetherOpenRemoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TV Remote"
    static let description = IntentDescription("Open the last-used paired LG TV remote in TapTether.")
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request("open")
        return .result()
    }
}

@available(iOS 18.0, *)
struct TapTetherPowerIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Power"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request("power")
        return .result()
    }
}

@available(iOS 18.0, *)
struct TapTetherVolumeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Up"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request("volumeUp")
        return .result()
    }
}

@available(iOS 18.0, *)
struct TapTetherVolumeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Down"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request("volumeDown")
        return .result()
    }
}

@available(iOS 18.0, *)
struct TapTetherMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Mute"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult {
        TapTetherSharedTV.request("mute")
        return .result()
    }
}
