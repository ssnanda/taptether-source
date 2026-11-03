import Foundation
import ActivityKit
import CryptoKit
import Security
import Darwin

/// Self-signed LG certificates are trusted ONLY when their DER SHA-256
/// fingerprint matches the saved device. Never silently fall back to ws://.
private final class TapTetherLgPinDelegate: NSObject, URLSessionDelegate {
    private let expected: String
    private(set) var mismatch = false

    init(expected: String) {
        self.expected = expected.uppercased()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                   URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(cert) as Data
        let observed = SHA256.hash(data: der).map {
            String(format: "%02X", $0)
        }.joined()
        if observed == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            mismatch = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

@available(iOS 18.0, *)
enum TapTetherLgRemoteNative {
    private static let permissions = [
        "LAUNCH", "LAUNCH_WEBAPP", "CLOSE", "CONTROL_AUDIO", "CONTROL_POWER",
        "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_INPUT_TEXT",
        "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
        "READ_RUNNING_APPS", "READ_INSTALLED_APPS", "READ_INPUT_DEVICE_LIST",
        "READ_CURRENT_CHANNEL"
    ]

    private static func validPrivateHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let ints = parts.compactMap { Int($0) }
        guard ints.count == 4, ints.allSatisfy({ $0 >= 0 && $0 <= 255 }),
              parts.allSatisfy({ String($0).count <= 3 }) else { return false }
        return ints[0] == 10 ||
            (ints[0] == 172 && (16...31).contains(ints[1])) ||
            (ints[0] == 192 && ints[1] == 168)
    }

    private static func validFingerprint(_ pin: String) -> Bool {
        pin.count == 64 && pin.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) ||
                (97...102).contains(byte)
        }
    }

    static func perform(_ action: TapTetherControlTarget) async throws {
        guard let defaults = TapTetherSharedTV.defaults,
              let host = defaults.string(forKey: TapTetherSharedTV.hostKey),
              let pin = defaults.string(forKey: TapTetherSharedTV.pinKey),
              validPrivateHost(host), validFingerprint(pin) else {
            throw TapTetherTVActionError.notPaired
        }
        // This Keychain item belongs to Runner, not the widget extension.
        // LiveActivityIntent executes in the main app's process without UI.
        let key = try TapTetherTVKeychain.read()
        var connected = true
        do {
            try await sendCommand(
                host: host, pin: pin, clientKey: key, action: action
            )
            if action == .power { connected = false }
        } catch let failure as TapTetherTVActionError {
            if action == .power && failure == .unavailable {
                guard let mac = defaults.string(forKey: TapTetherSharedTV.macKey),
                      sendWakePacket(mac: mac, host: host) else {
                    throw TapTetherTVActionError.noWakeAddress
                }
                connected = false
            } else {
                throw failure
            }
        }
        let label = defaults.string(forKey: TapTetherSharedTV.nameKey) ?? "LG TV"
        await updateActivity(host: host, title: label, connected: connected)
    }

    /// Read the actual LG power state via the saved TLS pin and device-only
    /// client key. This is strictly a read: background checks never wake,
    /// power on, or create a Lock Screen activity.
    static func selectedTVIsOn(host: String) async -> Bool {
        guard let defaults = TapTetherSharedTV.defaults,
              defaults.string(forKey: TapTetherSharedTV.hostKey) == host,
              let pin = defaults.string(forKey: TapTetherSharedTV.pinKey),
              validPrivateHost(host), validFingerprint(pin),
              let key = try? TapTetherTVKeychain.read() else {
            return false
        }
        let delegate = TapTetherLgPinDelegate(expected: pin)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config,
                                 delegate: delegate, delegateQueue: nil)
        guard let url = URL(string: "wss://\(host):3001") else {
            session.invalidateAndCancel()
            return false
        }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            let registration: [String: Any] = [
                "forcePairing": false,
                "pairingType": "PROMPT",
                "client-key": key,
                "manifest": [
                    "manifestVersion": 1,
                    "appVersion": "1.0",
                    "permissions": permissions
                ] as [String: Any]
            ]
            let answer = try await send(socket,
                id: "tt-monitor-register", type: "register",
                payload: registration)
            let response = answer["payload"] as? [String: Any] ?? [:]
            guard answer["type"] as? String == "registered",
                  response["client-key"] as? String == key else {
                return false
            }
            let status = try await request(socket,
                id: "tt-monitor-power",
                uri: "ssap://com.webos.service.tvpower/power/getPowerState")
            let state = (status["state"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return state == "active" || state == "screen saver"
        } catch {
            return false
        }
    }

    private static func makeMessage(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields)
        guard let message = String(data: data, encoding: .utf8) else {
            throw TapTetherTVActionError.rejected
        }
        return message
    }

    private static func readMessage(
        _ socket: URLSessionWebSocketTask,
        id: String
    ) async throws -> [String: Any] {
        for _ in 0..<8 {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .string(let string): bytes = Data(string.utf8)
            case .data(let data): bytes = data
            @unknown default: continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: bytes)
                    as? [String: Any] else {
                continue
            }
            if (json["id"] as? String) == id { return json }
        }
        throw TapTetherTVActionError.rejected
    }

    private static func send(
        _ socket: URLSessionWebSocketTask,
        id: String,
        type: String,
        uri: String? = nil,
        payload: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var json: [String: Any] = ["id": id, "type": type]
        if let uri = uri { json["uri"] = uri }
        if let payload = payload { json["payload"] = payload }
        try await socket.send(.string(makeMessage(json)))
        let result = try await readMessage(socket, id: id)
        if result["type"] as? String == "error" ||
            (result["payload"] as? [String: Any])?["returnValue"] as? Bool == false {
            throw TapTetherTVActionError.rejected
        }
        return result
    }

    private static func request(
        _ socket: URLSessionWebSocketTask,
        id: String, uri: String,
        payload: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let result = try await send(socket, id: id, type: "request",
                                    uri: uri, payload: payload)
        return result["payload"] as? [String: Any] ?? [:]
    }

    private static func sendCommand(
        host: String, pin: String, clientKey: String,
        action: TapTetherControlTarget
    ) async throws {
        let delegate = TapTetherLgPinDelegate(expected: pin)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 15
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config,
                                 delegate: delegate, delegateQueue: nil)
        guard let url = URL(string: "wss://\(host):3001") else {
            throw TapTetherTVActionError.invalidAddress
        }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            let registration: [String: Any] = [
                "forcePairing": false,
                "pairingType": "PROMPT",
                "client-key": clientKey,
                "manifest": [
                    "manifestVersion": 1,
                    "appVersion": "1.0",
                    "permissions": permissions
                ] as [String: Any]
            ]
            let answer = try await send(socket, id: "tt-lock-register",
                                        type: "register", payload: registration)
            let payload = answer["payload"] as? [String: Any] ?? [:]
            guard answer["type"] as? String == "registered",
                  let returnedKey = payload["client-key"] as? String,
                  !returnedKey.isEmpty else {
                throw TapTetherTVActionError.notPaired
            }
            // A different key may mean the TV requires new approval.
            guard returnedKey == clientKey else {
                throw TapTetherTVActionError.notPaired
            }
            switch action {
            case .power:
                _ = try await request(socket, id: "tt-lock-power",
                    uri: "ssap://system/turnOff")
            case .volumeUp:
                _ = try await request(socket, id: "tt-lock-volume-up",
                    uri: "ssap://audio/volumeUp")
            case .volumeDown:
                _ = try await request(socket, id: "tt-lock-volume-down",
                    uri: "ssap://audio/volumeDown")
            case .mute:
                let status = try await request(socket, id: "tt-lock-get-volume",
                    uri: "ssap://audio/getVolume")
                let muted = (status["muted"] as? Bool) ??
                    (status["mute"] as? Bool) ?? false
                _ = try await request(socket, id: "tt-lock-mute",
                    uri: "ssap://audio/setMute", payload: ["mute": !muted])
            case .home, .apps:
                try await sendPointerButton(socket, host: host,
                    session: session, button: "HOME")
            case .back:
                try await sendPointerButton(socket, host: host,
                    session: session, button: "BACK")
            case .ok:
                try await sendPointerButton(socket, host: host,
                    session: session, button: "ENTER")
            case .netflix, .youtube, .prime, .appleTV:
                let list = try await request(socket, id: "tt-lock-app-list",
                    uri: "ssap://com.webos.applicationManager/listLaunchPoints")
                guard let id = installedAppId(for: action, payload: list) else {
                    throw TapTetherTVActionError.appUnavailable
                }
                _ = try await request(socket, id: "tt-lock-app-launch",
                    uri: "ssap://com.webos.applicationManager/launch",
                    payload: ["id": id])
            }
        } catch let issue as TapTetherTVActionError {
            throw issue
        } catch {
            if delegate.mismatch { throw TapTetherTVActionError.identityMismatch }
            throw TapTetherTVActionError.unavailable
        }
    }

    private static func installedAppId(
        for target: TapTetherControlTarget,
        payload: [String: Any]
    ) -> String? {
        guard let points = payload["launchPoints"] as? [[String: Any]] else {
            return nil
        }
        let entries: [(id: String, title: String)] = points.compactMap { point in
            guard let id = point["id"] as? String,
                  let name = point["title"] as? String,
                  !id.isEmpty, id.count < 128 else { return nil }
            return (id: id, title: name)
        }
        let expected: [String]
        switch target {
        case .netflix: expected = ["netflix"]
        case .youtube: expected = ["youtube"]
        case .prime: expected = ["prime video", "amazon prime"]
        case .appleTV: expected = ["apple tv", "appletv"]
        default: return nil
        }
        let exact = entries.first {
            expected.contains($0.title.trimmingCharacters(in: .whitespaces)
                .lowercased())
        }
        if let exact = exact { return exact.id }
        return entries.first { entry in
            expected.contains(where: { name in
                entry.title.lowercased().contains(name) ||
                    entry.id.lowercased().contains(
                        name.replacingOccurrences(of: " ", with: ""))
            })
        }?.id
    }

    private static func sendPointerButton(
        _ socket: URLSessionWebSocketTask,
        host: String, session: URLSession, button: String
    ) async throws {
        guard ["HOME", "BACK", "ENTER"].contains(button) else {
            throw TapTetherTVActionError.rejected
        }
        let response = try await request(socket, id: "tt-lock-pointer",
            uri: "ssap://com.webos.service.networkinput/getPointerInputSocket")
        guard let socketPath = response["socketPath"] as? String,
              let url = URL(string: socketPath), url.host == host,
              (url.scheme == "ws" && url.port == 3000 ||
               url.scheme == "wss" && url.port == 3001) else {
            throw TapTetherTVActionError.rejected
        }
        let pointer = session.webSocketTask(with: url)
        pointer.resume()
        defer { pointer.cancel(with: .normalClosure, reason: nil) }
        try await pointer.send(.string("type:button\nname:\(button)\n\n"))
    }

    /// Best-effort LAN magic packet: broadcast only to the selected TV's
    /// saved MAC. This never sends registration keys or app commands.
    private static func sendWakePacket(mac: String, host: String) -> Bool {
        let hex = mac.replacingOccurrences(of: ":", with: "")
                     .replacingOccurrences(of: "-", with: "")
        guard hex.count == 12 else { return false }
        var addressBytes: [UInt8] = []
        for index in stride(from: 0, to: 12, by: 2) {
            let a = hex.index(hex.startIndex, offsetBy: index)
            let b = hex.index(a, offsetBy: 2)
            guard let byte = UInt8(hex[a..<b], radix: 16) else { return false }
            addressBytes.append(byte)
        }
        let packet = [UInt8](repeating: 0xff, count: 6) +
            Array(repeating: addressBytes, count: 16).flatMap { $0 }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let destinations = [
            "\(parts[0]).\(parts[1]).\(parts[2]).255",
            "255.255.255.255"
        ]
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var allow: Int32 = 1
        _ = withUnsafePointer(to: &allow) {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, $0,
                       socklen_t(MemoryLayout<Int32>.size))
        }
        var sent = false
        for destination in destinations {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, destination, &address.sin_addr) == 1
            else { continue }
            let count = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if count == packet.count { sent = true }
        }
        return sent
    }

    @MainActor
    private static func updateActivity(
        host: String, title: String, connected: Bool
    ) async {
        let now = Date()
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: now)
        for activity in Activity<TapTetherTVActivityAttributes>.activities
            where activity.attributes.pairedHost == host {
            let deadline = activity.content.state.expiresAt
            if !connected || deadline == nil || deadline! <= now ||
                hour < 9 || hour >= 21 {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            let updated = TapTetherTVActivityAttributes.ContentState(
                title: title, connected: true,
                layout: TapTetherSharedTV.lockLayout,
                expiresAt: deadline
            )
            await activity.update(ActivityContent(
                state: updated, staleDate: deadline))
        }
    }
}
