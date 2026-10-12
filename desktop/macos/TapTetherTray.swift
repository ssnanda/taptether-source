// TapTether desktop agent menu-bar UI. The actual Go agent runs separately
// under launchd and continues working if this UI quits.
// Bundled as TapTether Agent.app; no network or telemetry.
import AppKit
import Foundation
import Darwin

private let splashNotice = Notification.Name("com.taptether.agent.showSplash")
private let agentLabel = "com.taptether.agent"
private let controller = NSHomeDirectory() + "/.local/bin/taptetherctl-mac"

final class TapTetherMenu: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var splashWindow: NSPanel?
    private var activeVersion = "unknown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activeVersion = versionFromAgent()
        let menu = NSMenu()
        let version = NSMenuItem(title: "TapTether Agent v" + activeVersion,
                                 action: #selector(showSplash), keyEquivalent: "")
        version.target = self
        menu.addItem(version)
        statusLabel = NSMenuItem(title: "Status: checking…", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        add(menu, "Show TapTether", #selector(showSplash))
        add(menu, "Start agent", #selector(startAgent))
        add(menu, "Restart agent", #selector(restartAgent))
        add(menu, "Stop agent", #selector(stopAgent))
        add(menu, "Check for updates", #selector(checkUpdate))
        menu.addItem(.separator())
        add(menu, "Pairing instructions", #selector(pairingInstructions))
        add(menu, "Quit menu (agent stays running)", #selector(quitMenu))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let path = Bundle.main.path(forResource: "TapTether", ofType: "icns"),
               let icon = NSImage(contentsOfFile: path) {
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                       accessibilityDescription: "TapTether")
            }
            button.toolTip = "TapTether Agent v" + activeVersion
        }
        statusItem.menu = menu
        refreshStatus()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receiveSplash(_:)),
            name: splashNotice, object: nil,
            suspensionBehavior: .deliverImmediately)
        if CommandLine.arguments.contains("--splash") {
            showSplash()
        }
    }

    // macOS may reactivate the already-running Login Item rather than start a
    // second process when the user opens TapTether Agent.app from Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showSplash()
        return true
    }

    private func add(_ menu: NSMenu, _ name: String, _ action: Selector) {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func output(_ executable: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return task.terminationStatus == 0
                ? (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        } catch {
            return ""
        }
    }

    private func versionFromAgent() -> String {
        let version = output(NSHomeDirectory() + "/.local/bin/taptether-agent", ["--version"])
        return version.isEmpty ? "unknown" : version
    }

    private func refreshStatus() {
        let target = "gui/" + String(getuid()) + "/" + agentLabel
        let state = output("/bin/launchctl", ["print", target])
        let isRunning = state.contains("state = running")
        statusLabel?.title = "Status: " + (isRunning ? "Running" : "Stopped")
    }

    private func showNotice(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func runControl(_ verb: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.output(controller, [verb])
            DispatchQueue.main.async {
                self.refreshStatus()
                self.showNotice("TapTether " + verb,
                    result.isEmpty ? "Could not confirm the operation. Check the service status or use the terminal."
                                   : String(result.prefix(1000)))
            }
        }
    }

    @objc private func startAgent() { runControl("start") }
    @objc private func restartAgent() { runControl("restart") }
    @objc private func stopAgent() { runControl("stop") }
    @objc private func checkUpdate() { runControl("check-update") }
    @objc private func quitMenu() { NSApp.terminate(nil) }
    @objc private func pairingInstructions() {
        showNotice("Pairing with TapTether",
            "On a trusted Mac Terminal, run:\n\n~/.local/bin/taptetherctl-mac pairing-qr\n\n"
            + "The menu does not expose pairing tokens or fingerprints.")
    }

    @objc private func receiveSplash(_ notification: Notification) {
        showSplash()
    }

    @objc private func showSplash() {
        if let window = splashWindow {
            window.orderFrontRegardless()
            return
        }
        let width: CGFloat = 380, height: CGFloat = 260
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "TapTether Agent"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.center()
        if let image = NSImage(contentsOfFile: Bundle.main.path(
            forResource: "TapTether", ofType: "icns") ?? "") {
            let view = NSImageView(frame: NSRect(x: 146, y: 137, width: 88, height: 88))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            panel.contentView?.addSubview(view)
        }
        func label(_ text: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
            let textField = NSTextField(labelWithString: text)
            textField.frame = NSRect(x: 15, y: y, width: width - 30, height: 30)
            textField.alignment = .center
            textField.font = bold
                ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            panel.contentView?.addSubview(textField)
        }
        label("TapTether Agent", y: 105, size: 22, bold: true)
        label("Your devices. Your control. Your network.", y: 75, size: 12)
        label("Version " + activeVersion, y: 44, size: 12)
        splashWindow = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.splashWindow = nil
        }
    }
}

// Only one menu-bar process per desktop user. Clicking the installed
// TapTether Agent.app forwards a splash request to the already-running tray.
let lockPath = NSTemporaryDirectory() + "taptether-tray-" + String(getuid()) + ".lock"
let lockFD = Darwin.open(lockPath, O_RDWR | O_CREAT, mode_t(0o600))
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(
        splashNotice, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = TapTetherMenu()
app.delegate = delegate
app.run()
