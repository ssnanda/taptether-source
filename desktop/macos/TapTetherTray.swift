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
        add(menu, "Install / Repair agent…", #selector(installAgent))
        add(menu, "Start agent", #selector(startAgent))
        add(menu, "Restart agent", #selector(restartAgent))
        add(menu, "Stop agent", #selector(stopAgent))
        add(menu, "Check for updates", #selector(checkUpdate))
        menu.addItem(.separator())
        add(menu, "Show pairing details", #selector(pairingInstructions))
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
        if !FileManager.default.isExecutableFile(atPath: controller),
           Bundle.main.path(forResource: "taptetherctl-mac", ofType: nil) != nil {
            DispatchQueue.main.async { [weak self] in self?.promptSetup() }
        }
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
        if !version.isEmpty { return version }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
    }

    private func refreshStatus() {
        let target = "gui/" + String(getuid()) + "/" + agentLabel
        let state = output("/bin/launchctl", ["print", target])
        let installed = FileManager.default.isExecutableFile(atPath: controller)
        let isRunning = state.contains("state = running")
        statusLabel?.title = "Status: " + (isRunning ? "Running" :
            (installed ? "Stopped — use Start / Repair" : "Not installed"))
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

    private func promptSetup() {
        let prompt = NSAlert()
        prompt.messageText = "Install TapTether Agent?"
        prompt.informativeText = "This installs a background agent that starts at login, "
            + "and keeps the menu-bar app available without a Terminal window. "
            + "You'll need to allow Accessibility access in macOS settings."
        prompt.addButton(withTitle: "Install & Start")
        prompt.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if prompt.runModal() == .alertFirstButtonReturn {
            installAgent()
        }
    }

    @objc private func installAgent() {
        guard let setup = Bundle.main.path(forResource: "taptetherctl-mac",
                                          ofType: nil) else {
            showNotice("Installer files not found",
                "Use the TapTether Agent.app bundled in the current macOS release.")
            return
        }
        statusLabel?.title = "Status: Installing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [setup, "install"]
            // Installation output contains private pairing material: discard it.
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try task.run()
                task.waitUntilExit()
                ok = task.terminationStatus == 0
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                self.refreshStatus()
                if ok {
                    self.activeVersion = self.versionFromAgent()
                    self.showNotice("TapTether installed",
                        "The background agent has been installed. "
                        + "Check that its status is Running, then open "
                        + "System Settings → Privacy & Security → Accessibility "
                        + "and allow TapTether. Use Show pairing details to pair.")
                } else {
                    self.showNotice("Installation needs attention",
                        "The agent could not be installed or started. "
                        + "Check ~/Library/Logs/TapTether/agent.stderr.log. "
                        + "Try Install / Repair again after checking permissions.")
                }
            }
        }
    }

    @objc private func startAgent() {
        if !FileManager.default.isExecutableFile(atPath: controller) {
            promptSetup()
            return
        }
        runControl("start")
    }
    @objc private func restartAgent() { runControl("restart") }
    @objc private func stopAgent() { runControl("stop") }
    @objc private func checkUpdate() { runControl("check-update") }
    @objc private func quitMenu() { NSApp.terminate(nil) }
    @objc private func pairingInstructions() {
        guard FileManager.default.isExecutableFile(atPath: controller) else {
            promptSetup()
            return
        }
        let details = output(controller, ["pairing"])
        if details.isEmpty {
            showNotice("Agent not ready",
                "Start or repair the agent, then try showing pairing details.")
            return
        }
        showNotice("Private pairing details",
            details + "\n\nKeep the pairing token private. "
            + "Enter these values in TapTether on your phone.")
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
