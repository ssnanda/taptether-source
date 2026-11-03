import ActivityKit
import Flutter
import UIKit

/// Flutter shares the selected LG TV's identity with the widget, while
/// copying its pairing key into Runner-only device Keychain storage.
/// Background LiveActivityIntent calls run native SSAP in the app process.
final class TapTetherTVControlsBridge {
    private var channel: FlutterMethodChannel?
    private var observer: NSObjectProtocol?

    func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "taptether/tv-controls",
            binaryMessenger: messenger
        )
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "NOT_READY", message: nil, details: nil))
                return
            }
            switch call.method {
            case "select":
                guard let data = call.arguments as? [String: Any],
                      let host = data["host"] as? String,
                      let name = data["name"] as? String,
                      let certificate = data["tlsPin"] as? String,
                      let clientKey = data["clientKey"] as? String,
                      !host.isEmpty, !name.isEmpty,
                      certificate.count == 64, !clientKey.isEmpty else {
                    result(FlutterError(code: "PINNED_TV_REQUIRED",
                        message: "Use an encrypted and paired LG TV.", details: nil))
                    return
                }
                // The token is duplicated only into Runner's device-only
                // Keychain, never into widget extension storage or defaults.
                do {
                    try TapTetherTVKeychain.save(clientKey)
                } catch {
                    result(FlutterError(code: "KEYCHAIN",
                        message: "Cannot prepare background TV control.",
                        details: nil))
                    return
                }
                guard let defaults = TapTetherSharedTV.defaults else {
                    result(FlutterError(code: "APP_GROUP",
                        message: "TV control storage unavailable.",
                        details: nil))
                    return
                }
                defaults.set(host, forKey: TapTetherSharedTV.hostKey)
                defaults.set(name, forKey: TapTetherSharedTV.nameKey)
                defaults.set(certificate.uppercased(),
                             forKey: TapTetherSharedTV.pinKey)
                defaults.set(data["macAddress"] as? String ?? "",
                             forKey: TapTetherSharedTV.macKey)
                let connected = data["connected"] as? Bool ?? false
                if #available(iOS 18.0, *) {
                    Task { @MainActor in
                        await self.showActivity(host: host, name: name,
                                                connected: connected)
                        result(true)
                    }
                } else {
                    result(false)
                }
            case "consume":
                guard let defaults = TapTetherSharedTV.defaults else {
                    result(nil)
                    return
                }
                let pending = defaults.string(forKey: TapTetherSharedTV.actionKey)
                defaults.removeObject(forKey: TapTetherSharedTV.actionKey)
                if let pending = pending,
                   let host = defaults.string(forKey: TapTetherSharedTV.hostKey) {
                    result(["action": pending, "host": host])
                } else {
                    result(nil)
                }
            case "stop":
                if #available(iOS 18.0, *) {
                    Task { @MainActor in
                        for activity in Activity<TapTetherTVActivityAttributes>.activities {
                            await activity.end(nil, dismissalPolicy: .immediate)
                        }
                        result(true)
                    }
                } else {
                    result(false)
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.channel?.invokeMethod("pendingControl", arguments: nil)
        }
    }

    @available(iOS 18.0, *)
    @MainActor private func showActivity(host: String, name: String,
                                          connected: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = TapTetherTVActivityAttributes.ContentState(
            title: name, connected: connected
        )
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(3600))
        let all = Activity<TapTetherTVActivityAttributes>.activities
        for activity in all where activity.attributes.pairedHost != host {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if let existing = all.first(where: {
            $0.attributes.pairedHost == host
        }) {
            await existing.update(content)
        } else {
            do {
                _ = try Activity.request(
                    attributes: TapTetherTVActivityAttributes(pairedHost: host),
                    content: content, pushType: nil
                )
            } catch {
                // Live Activities are optional; the normal remote still works.
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
