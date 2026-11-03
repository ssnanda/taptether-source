import ActivityKit
import BackgroundTasks
import Flutter
import Network
import UIKit

/// Flutter shares the selected LG TV's identity with the widget, while
/// copying its pairing key into Runner-only device Keychain storage.
/// Background LiveActivityIntent calls run native SSAP in the app process.
final class TapTetherTVControlsBridge {
    private var channel: FlutterMethodChannel?
    private var observer: NSObjectProtocol?
    private var wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var wifiConnected = false
    private var expirationTimer: Timer?

    func register(messenger: FlutterBinaryMessenger) {
        // A cellular connection must never keep a local-TV activity visible.
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wifiConnected = path.status == .satisfied &&
                    path.usesInterfaceType(.wifi)
                if #available(iOS 18.0, *) {
                    Task { @MainActor in
                        if !self.wifiConnected {
                            await self.dismissAllActivities()
                        } else {
                            await TapTetherTVActivityExpiry.dismissExpired()
                        }
                    }
                }
            }
        }
        wifiMonitor.start(queue: DispatchQueue(
            label: "com.taptether.tv-controls.wifi"))

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
                let powerOn = data["tvPowerOn"] as? Bool ?? false
                if #available(iOS 18.0, *) {
                    Task { @MainActor in
                        if TapTetherTVActivityPolicy.allowed(
                            connected: connected, powerOn: powerOn,
                            wifi: self.wifiConnected
                        ) {
                            await self.showActivity(host: host, name: name)
                        } else {
                            await self.dismissAllActivities()
                        }
                        result(true)
                    }
                } else {
                    result(false)
                }
            case "getLayout":
                result(TapTetherSharedTV.lockLayout)
            case "setLayout":
                guard let value = call.arguments as? String,
                      value == "compact" || value == "wide",
                      let defaults = TapTetherSharedTV.defaults else {
                    result(FlutterError(code: "INVALID_LAYOUT",
                        message: "Select Compact or Wide.", details: nil))
                    return
                }
                defaults.set(value, forKey: TapTetherSharedTV.layoutKey)
                if #available(iOS 18.0, *) {
                    Task { @MainActor in
                        // Force the widget extension to render the new sizing
                        // without needing to reopen the Flutter remote.
                        for activity in Activity<TapTetherTVActivityAttributes>.activities {
                            let previous = activity.content.state
                            let state = TapTetherTVActivityAttributes.ContentState(
                                title: previous.title,
                                connected: previous.connected,
                                layout: value,
                                expiresAt: previous.expiresAt
                            )
                            await activity.update(ActivityContent(
                                state: state, staleDate: previous.expiresAt))
                        }
                        result(true)
                    }
                } else {
                    result(true)
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
                        await self.dismissAllActivities()
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
            if #available(iOS 18.0, *) {
                Task { @MainActor in
                    await TapTetherTVActivityExpiry.dismissExpired()
                    if self?.wifiConnected != true {
                        await self?.dismissAllActivities()
                    }
                }
            }
        }
    }

    @available(iOS 18.0, *)
    @MainActor private func dismissAllActivities() async {
        expirationTimer?.invalidate()
        expirationTimer = nil
        TapTetherTVActivityExpiry.cancel()
        for activity in Activity<TapTetherTVActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @available(iOS 18.0, *)
    @MainActor private func showActivity(host: String, name: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await TapTetherTVActivityExpiry.dismissExpired()
        let now = Date()
        let all = Activity<TapTetherTVActivityAttributes>.activities
        // An existing panel retains its original 15-minute deadline.
        let original = all.first(where: { $0.attributes.pairedHost == host })
        let deadline = original?.content.state.expiresAt ??
            TapTetherTVActivityPolicy.deadline(from: now)
        guard deadline > now else {
            await dismissAllActivities()
            return
        }
        for activity in all where activity.attributes.pairedHost != host {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let state = TapTetherTVActivityAttributes.ContentState(
            title: name, connected: true,
            layout: TapTetherSharedTV.lockLayout,
            expiresAt: deadline
        )
        let content = ActivityContent(state: state, staleDate: deadline)
        if let existing = original {
            await existing.update(content)
        } else {
            do {
                _ = try Activity.request(
                    attributes: TapTetherTVActivityAttributes(pairedHost: host),
                    content: content, pushType: nil
                )
            } catch {
                // Optional on-device widget; the remote continues working.
                return
            }
        }
        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, deadline.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in await self?.dismissAllActivities() }
        }
        TapTetherTVActivityExpiry.schedule(at: deadline)
    }

    deinit {
        expirationTimer?.invalidate()
        wifiMonitor.cancel()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}


/// iOS background refresh is opportunistic, not guaranteed to execute at
/// its earliestBeginDate. Explicit staleDate and foreground/network cleanup
/// complement this task; activity state is never extended by a refresh.
@available(iOS 18.0, *)
enum TapTetherTVActivityExpiry {
    static let identifier = "com.taptether.taptether.tv-controls-expire"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let operation = Task { @MainActor in
                await dismissExpired()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { operation.cancel() }
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    static func schedule(at deadline: Date) {
        cancel()
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = deadline
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func dismissExpired() async {
        let now = Date()
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: now)
        for activity in Activity<TapTetherTVActivityAttributes>.activities {
            let deadline = activity.content.state.expiresAt
            if deadline == nil || deadline! <= now || hour < 9 || hour >= 21 {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
