import Foundation
import AppIntents
import ActivityKit
import Security

/// Shared UI state contains only the selected TV's address and label.
/// The LG pairing key stays in the Runner's device-only iOS Keychain.
enum TapTetherSharedTV {
    static let group = "group.com.taptether.taptether.controls"
    static let hostKey = "lastLgHost"
    static let nameKey = "lastLgName"
    static let pinKey = "lastLgCertificate"
    static let macKey = "lastLgMac"
    static let actionKey = "pendingLgAction" // Migrates older foreground shortcuts.
    static let layoutKey = "lockScreenLayout"
    static var lockLayout: String {
        defaults?.string(forKey: layoutKey) == "wide" ? "wide" : "compact"
    }
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
}

/// Native, device-only keychain copy of the currently selected LG client key.
/// The Swift runner writes this after Flutter reads its existing secure store.
/// Widget extensions never receive this secret through UserDefaults.
enum TapTetherTVKeychain {
    static let service = "com.taptether.taptether.lg-controls"
    static let account = "selected-client-key"

    static func save(_ clientKey: String) throws {
        guard !clientKey.isEmpty else { throw TapTetherTVActionError.notPaired }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(lookup as CFDictionary)
        var attributes = lookup
        attributes[kSecValueData as String] = Data(clientKey.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else {
            throw TapTetherTVActionError.keychainUnavailable
        }
    }

    static func read() throws -> String {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw TapTetherTVActionError.notPaired
        }
        return token
    }
}

enum TapTetherTVActionError: LocalizedError, Equatable {
    case notPaired
    case keychainUnavailable
    case invalidAddress
    case identityMismatch
    case unavailable
    case rejected
    case appUnavailable
    case noWakeAddress

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Open TapTether once and select a paired LG TV."
        case .keychainUnavailable: return "TV Keychain credentials are unavailable."
        case .invalidAddress: return "Selected TV is not on a private LAN address."
        case .identityMismatch: return "The TV certificate has changed; reconnect in TapTether."
        case .unavailable: return "TV is not reachable on local Wi-Fi."
        case .rejected: return "The LG TV rejected this command."
        case .appUnavailable: return "This app is not installed or exposed by the LG TV."
        case .noWakeAddress: return "TV wake needs a saved Wi-Fi MAC address."
        }
    }
}

@available(iOS 16.2, *)
struct TapTetherTVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var connected: Bool
        // Optional to preserve decoding of Live Activities from older builds.
        var layout: String?
        // Optional for existing Live Activities after an app update.
        var expiresAt: Date?
    }
    var pairedHost: String
}

/// A TV control may start only on the phone's Wi-Fi, with confirmed TV power
/// and inside the 09:00–21:00 local window. It never runs for more than 15 min.
@available(iOS 18.0, *)
enum TapTetherTVActivityPolicy {
    static let lifetime: TimeInterval = 15 * 60
    static func allowed(connected: Bool, powerOn: Bool, wifi: Bool,
                        now: Date = Date()) -> Bool {
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: now)
        return connected && powerOn && wifi && hour >= 9 && hour < 21
    }

    static func deadline(from start: Date = Date()) -> Date {
        let nightly = Calendar.autoupdatingCurrent.date(
            bySettingHour: 21, minute: 0, second: 0, of: start
        ) ?? start
        return min(start.addingTimeInterval(lifetime), nightly)
    }
}

@available(iOS 18.0, *)
enum TapTetherControlTarget: String, AppEnum {
    case power, volumeUp, volumeDown, mute, home, back, ok
    case netflix, youtube, prime, appleTV, playPause

    static var typeDisplayRepresentation = TypeDisplayRepresentation("TV action")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .power: DisplayRepresentation("Power"),
        .volumeUp: DisplayRepresentation("Volume up"),
        .volumeDown: DisplayRepresentation("Volume down"),
        .mute: DisplayRepresentation("Mute"),
        .home: DisplayRepresentation("TV home"),
        .back: DisplayRepresentation("TV back"),
        .ok: DisplayRepresentation("TV OK"),
        .netflix: DisplayRepresentation("Netflix"),
        .youtube: DisplayRepresentation("YouTube"),
        .prime: DisplayRepresentation("Prime Video"),
        .appleTV: DisplayRepresentation("Apple TV"),
        .playPause: DisplayRepresentation("TV Play/Pause")
    ]
}

/// LiveActivityIntent runs in the containing app's process, without needing
/// a visible Flutter screen. The native executor uses Keychain + TLS pinning.
/// WidgetKit may require the user to unlock the phone before it runs.
@available(iOS 18.0, *)
struct TapTetherTVActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "TapTether TV control"
    static let description = IntentDescription(
        "Control the last selected, securely paired LG TV on local Wi-Fi."
    )
    // IntentModes was introduced in iOS 26. Older iOS versions execute
    // LiveActivityIntent in Runner's background process by default.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Action")
    var target: TapTetherControlTarget

    init() { target = .home }
    init(target: TapTetherControlTarget) { self.target = target }

    func perform() async throws -> some IntentResult {
        try await TapTetherLgRemoteNative.perform(target)
        return .result()
    }
}
