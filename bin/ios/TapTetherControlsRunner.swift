import ActivityKit
import Flutter
import UIKit

/// Flutter communication lives in Runner; AppIntent and widget code never
/// receives the LG pairing key or any other authentication secret.
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
                      !host.isEmpty, !name.isEmpty else {
                    result(FlutterError(code: "INVALID_TV", message: nil, details: nil))
                    return
                }
                TapTetherSharedTV.defaults?.set(host, forKey: TapTetherSharedTV.hostKey)
                TapTetherSharedTV.defaults?.set(name, forKey: TapTetherSharedTV.nameKey)
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
