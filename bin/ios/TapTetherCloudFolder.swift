import UIKit
import Flutter
import UniformTypeIdentifiers

// A user-selected Files/iCloud Drive directory works without private
// CloudKit containers or new iCloud signing entitlements. Bookmarks only
// survive app launches, not app deletion; encrypted backup files survive.
final class TapTetherCloudFolder: NSObject, UIDocumentPickerDelegate {
    private static let bookmarkKey = "taptether.auto-backup.folder-bookmark.v1"
    private let defaults = UserDefaults.standard
    private var pendingPicker: FlutterResult?
    private var channel: FlutterMethodChannel?

    func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "taptether.device_backup.folder.v1",
            binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "CLOSED", message: "Folder handler unavailable", details: nil))
                return
            }
            switch call.method {
            case "selectFolder":
                self.selectFolder(result)
            case "status":
                result(self.folderStatus())
            case "writeBackup":
                self.writeBackup(call, result)
            case "clearFolder":
                self.defaults.removeObject(forKey: Self.bookmarkKey)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private var presentingController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var controller = scene?.windows.first(where: { $0.isKeyWindow })?
            .rootViewController else {
            return nil
        }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func selectedURL() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            return nil
        }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              bookmarkDataIsStale: &stale)
            if stale {
                defaults.removeObject(forKey: Self.bookmarkKey)
                return nil
            }
            return url
        } catch {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
    }

    private func folderStatus() -> [String: Any] {
        guard let url = selectedURL() else {
            return ["available": false]
        }
        let access = url.startAccessingSecurityScopedResource()
        if access { url.stopAccessingSecurityScopedResource() }
        return ["available": access,
                "folder": url.lastPathComponent,
                "location": "Files / " + url.lastPathComponent]
    }

    private func selectFolder(_ result: @escaping FlutterResult) {
        guard pendingPicker == nil else {
            result(FlutterError(code: "BUSY", message: "Folder picker is open", details: nil))
            return
        }
        guard #available(iOS 14, *) else {
            result(FlutterError(code: "IOS_VERSION", message: "iOS 14+ required", details: nil))
            return
        }
        guard let presenter = presentingController else {
            result(FlutterError(code: "NO_UI", message: "No screen for picker", details: nil))
            return
        }
        pendingPicker = result
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPicker?(false)
        pendingPicker = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let selected = urls.first else {
            pendingPicker?(false)
            pendingPicker = nil
            return
        }
        guard selected.startAccessingSecurityScopedResource() else {
            pendingPicker?(FlutterError(code: "PERMISSION",
                message: "Files did not grant access to that folder", details: nil))
            pendingPicker = nil
            return
        }
        defer { selected.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try selected.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            pendingPicker?(true)
        } catch {
            pendingPicker?(FlutterError(code: "BOOKMARK",
                message: "Unable to retain folder permission", details: nil))
        }
        pendingPicker = nil
    }

    private func writeBackup(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let data = call.arguments as? [String: Any],
              let encoded = data["bytes"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INPUT", message: "Encrypted backup data missing", details: nil))
            return
        }
        guard !encoded.data.isEmpty && encoded.data.count <= 4 * 1024 * 1024 else {
            result(FlutterError(code: "SIZE", message: "Encrypted backup size invalid", details: nil))
            return
        }
        let encrypted = encoded.data
        // iCloud Drive / third-party file providers can block during writes.
        // Never run coordinated file I/O on the UI/platform-channel thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let folder = self.selectedURL(),
                  folder.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FOLDER",
                        message: "Select an accessible iCloud Drive folder again",
                        details: nil))
                }
                return
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            var coordinatedError: NSError?
            var writeError: Error?
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let filename = "TapTether-Auto-" + formatter.string(from: Date()) +
                "-" + String(UUID().uuidString.prefix(8)) + ".ttbackup"

            NSFileCoordinator().coordinate(
                writingItemAt: folder, options: .forMerging,
                error: &coordinatedError) { writableFolder in
                    do {
                        let output = writableFolder.appendingPathComponent(filename)
                        try encrypted.write(to: output, options: .atomic)
                        let attrs = try FileManager.default.attributesOfItem(
                            atPath: output.path)
                        guard (attrs[.size] as? NSNumber)?.intValue == encrypted.count
                            else {
                            throw NSError(domain: "TapTetherBackup", code: 11,
                                userInfo: [NSLocalizedDescriptionKey: "File verification failed"])
                        }
                        // Retain five verified encrypted generations.
                        let contents = try FileManager.default.contentsOfDirectory(
                            at: writableFolder,
                            includingPropertiesForKeys: [.contentModificationDateKey])
                        let backups = contents.filter {
                            $0.lastPathComponent.hasPrefix("TapTether-Auto-") &&
                            $0.pathExtension == "ttbackup"
                        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                        for old in backups.dropFirst(5) {
                            try? FileManager.default.removeItem(at: old)
                        }
                    } catch {
                        writeError = error
                    }
                }

            let failure = coordinatedError ?? (writeError as NSError?)
            DispatchQueue.main.async {
                if let error = failure {
                    result(FlutterError(code: "WRITE",
                        message: error.localizedDescription, details: nil))
                } else {
                    // A successful coordinated write is not proof that iCloud
                    // has finished synchronizing the file across devices.
                    result(["saved": true, "filename": filename,
                            "folder": folder.lastPathComponent,
                            "location": "Files / " + folder.lastPathComponent])
                }
            }
        }
    }
}
