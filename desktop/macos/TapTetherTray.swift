// TapTether desktop agent menu-bar UI. The actual Go agent runs separately
// under launchd and continues working if this UI quits.
// Bundled as TapTether Agent.app; no network or telemetry.
import AppKit
import Foundation
import Darwin

private let splashNotice = Notification.Name("com.taptether.agent.showSplash")
private let agentLabel = "com.taptether.agent"
private let coreLabel = "com.taptether.input-core"
private let controller = NSHomeDirectory() + "/.local/bin/taptetherctl-mac"

final class TapTetherMenu: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var versionMenuItem: NSMenuItem!
    private var updateMenuItem: NSMenuItem!
    private var updateInProgress = false
    private var remoteShutdownItem: NSMenuItem!
    private var splashWindow: NSPanel?
    private var activeVersion = "unknown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activeVersion = versionFromAgent()
        let menu = NSMenu()
        let version = NSMenuItem(title: "TapTether Agent v" + activeVersion,
                                 action: #selector(showSplash), keyEquivalent: "")
        version.target = self
        versionMenuItem = version
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
        updateMenuItem = NSMenuItem(title: "Update Agent…",
                                  action: #selector(updateAgent), keyEquivalent: "")
        updateMenuItem.target = self
        menu.addItem(updateMenuItem)
        remoteShutdownItem = NSMenuItem(
            title: "Allow remote shutdown", action: #selector(toggleRemoteShutdown),
            keyEquivalent: "")
        remoteShutdownItem.target = self
        remoteShutdownItem.state = .off
        menu.addItem(remoteShutdownItem)
        add(menu, "Agent diagnostics", #selector(showAgentDiagnostics))
        add(menu, "Repair Accessibility…", #selector(repairAccessibility))
        add(menu, "Open Accessibility settings", #selector(openAccessibilitySettings))
        menu.addItem(.separator())
        add(menu, "Show pairing details", #selector(pairingInstructions))
        add(menu, "Uninstall TapTether…", #selector(uninstallTapTether))
        add(menu, "Quit TapTether (stop agent & menu)", #selector(quitMenu))
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
        // Installed user agents sometimes remain unloaded after first login
        // or an app update. Re-establish the LaunchAgent once, off the UI
        // thread, without opening Terminal or showing unwanted popups.
        if FileManager.default.isExecutableFile(atPath: controller) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let target = "gui/" + String(getuid()) + "/" + agentLabel
                let state = self.output("/bin/launchctl", ["print", target])
                if !state.contains("state = running") {
                    _ = self.output(controller, ["start"])
                }
                DispatchQueue.main.async { self.refreshStatus() }
            }
        }
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

    private func remoteShutdownEnabled() -> Bool {
        let plistPath = NSHomeDirectory()
            + "/Library/LaunchAgents/com.taptether.agent.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let vars = plist["EnvironmentVariables"] as? [String: Any]
        else { return false }
        return vars["TAPTETHER_ENABLE_SHUTDOWN"] as? String == "1"
    }

    private func refreshStatus() {
        let installedVersion = versionFromAgent()
        if installedVersion != activeVersion {
            activeVersion = installedVersion
            versionMenuItem?.title = "TapTether Agent v" + installedVersion
            statusItem?.button?.toolTip = "TapTether Agent v" + installedVersion
        }
        remoteShutdownItem?.state = remoteShutdownEnabled() ? .on : .off
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
                let observed = self.statusLabel?.title ?? "Status unavailable"
                self.showNotice("TapTether " + verb,
                    result.isEmpty ? observed + ". If stopped, choose Install / Repair agent."
                                   : String(result.prefix(1000)))
            }
        }
    }

    private func promptSetup() {
        let prompt = NSAlert()
        prompt.messageText = "Install TapTether Agent?"
        prompt.informativeText = "This installs a background agent that starts at login, "
            + "and keeps the menu-bar app available without a Terminal window. "
            + "You'll need to allow the stable Input Core in Accessibility once."
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
                    let alert = NSAlert()
                    alert.messageText = "TapTether installed / repaired"
                    alert.informativeText = "Agent and Input Core are running. "
                        + "For this one-time migration, allow taptether-input-core "
                        + "in Accessibility. Future agent updates preserve the core."
                    alert.addButton(withTitle: "Open Accessibility…")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        self.openAccessibilitySettings()
                    }
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
    @objc private func updateAgent() {
        if updateInProgress { return }
        guard FileManager.default.isExecutableFile(atPath: controller) else {
            promptSetup()
            return
        }
        let prompt = NSAlert()
        prompt.messageText = "Update TapTether Agent?"
        prompt.informativeText = "Check the latest published release and install it " +
            "if a newer version is available. The agent may briefly disconnect. " +
            "Your paired phones and local settings will be preserved."
        prompt.addButton(withTitle: "Update Agent")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if prompt.runModal() != .alertFirstButtonReturn { return }
        updateInProgress = true
        updateMenuItem.isEnabled = false
        statusLabel?.title = "Status: Updating…"

        // The updater can replace the agent and tray. Its output must not be
        // displayed because legacy installers printed private pairing tokens.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [controller, "update"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var succeeded = false
            do {
                try task.run()
                task.waitUntilExit()
                succeeded = task.terminationStatus == 0
            } catch {
                succeeded = false
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updateInProgress = false
                self.updateMenuItem.isEnabled = true
                self.refreshStatus()
                if succeeded {
                    self.showNotice("TapTether update complete",
                        "Installed version: " + self.activeVersion +
                        ". The agent and menu may restart briefly.")
                } else {
                    self.showNotice("Update could not finish",
                        "The previously installed agent remains available. " +
                        "Try Update Agent again; if it still fails, " +
                        "use Agent diagnostics.")
                }
            }
        }
    }

    @objc private func toggleRemoteShutdown() {
        // Persist via the local controller. The installed agent has its own
        // opt-out marker, so disabling survives repair and auto-update.
        let enabled = remoteShutdownEnabled()
        runControl(enabled ? "disable-shutdown" : "enable-shutdown")
    }
    @objc private func showAgentDiagnostics() {
        // Read a fixed-format, privacy-safe status report. Do not copy raw
        // log lines or launchctl dumps (which might include pairing material).
        let report = output(controller, ["diagnostics"])
        let message = report.isEmpty
            ? "Agent diagnostics unavailable. Select Install / Repair agent, then retry."
            : report
        let alert = NSAlert()
        alert.messageText = "TapTether Agent Diagnostics"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy diagnostics")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            clipboard.setString(message, forType: .string)
            showNotice("Diagnostics copied",
                "Paste the report into ChatGPT to troubleshoot this Mac without Terminal.")
        }
    }
    @objc private func repairAccessibility() {
        let corePath = NSHomeDirectory() + "/.local/bin/taptether-input-core"
        guard FileManager.default.isExecutableFile(atPath: corePath) else {
            showNotice("TapTether Input Core not installed",
                "Install / Repair agent first, then repair Accessibility.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Repair mouse & keyboard permission"
        alert.informativeText = "TapTether now keeps input permission in a stable "
            + "Input Core that routine agent updates do not replace.\n\n"
            + "1. In System Settings → Privacy & Security → Accessibility, "
            + "remove any old taptether-agent entry.\n"
            + "2. Click + to add the Input Core. Press "
            + "Command-Shift-G in the file chooser, then paste:\n"
            + corePath + "\n"
            + "3. Enable the new entry. Return to the TapTether tray "
            + "and choose Restart agent. This approval should only be needed "
            + "again after an explicitly authorized Input Core upgrade.\n\n"
            + "This does not erase phone pairings."
        alert.addButton(withTitle: "Copy path & open settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(corePath, forType: .string)
        openAccessibilitySettings()
    }

    @objc private func uninstallTapTether() {
        guard FileManager.default.isExecutableFile(atPath: controller) else {
            showNotice("Uninstaller unavailable",
                "TapTether controller is missing. Install / Repair agent to "
                + "restore it before uninstalling.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall TapTether from this Mac?"
        alert.alertStyle = .warning
        alert.informativeText = "This stops and removes the background agent, "
            + "menu-bar app, launch-at-login items, helper executables and logs. "
            + "It does not change any other apps.\n\n"
            + "Keep pairings: preserve device keys and trusted phone list "
            + "for a future reinstall.\n"
            + "Erase everything: permanently delete TapTether's local "
            + "pairing token, certificates, authorized phones and settings. "
            + "Your iPhone will need to pair again.\n\n"
            + "macOS Accessibility entries must still be removed manually "
            + "in System Settings."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall · Keep Pairings")
        alert.addButton(withTitle: "Uninstall & Erase Everything")
        NSApp.activate(ignoringOtherApps: true)
        let selection = alert.runModal()
        if selection == .alertFirstButtonReturn { return }
        let erase = selection == .alertThirdButtonReturn
        if erase {
            let confirm = NSAlert()
            confirm.messageText = "Permanently erase TapTether pairing data?"
            confirm.alertStyle = .critical
            confirm.informativeText = "Authorized phones, private keys, "
                + "TLS certificates and settings will be deleted. "
                + "This cannot be undone. Existing phones must pair again."
            confirm.addButton(withTitle: "Erase & Uninstall")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() != .alertFirstButtonReturn { return }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [controller, "uninstall",
                          erase ? "--erase-pairing" : "--keep-pairing"]
        // Do not surface installer output or secrets in the menu UI.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // The uninstaller itself bootouts this tray after stopping the
            // agent. Do not exit first and risk aborting the cleanup process.
        } catch {
            showNotice("Uninstall could not start",
                "The agent is still installed. Try again from the tray.")
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitMenu() {
        // Quit means the background agent must stop too, not merely hide
        // the tray. launchctl bootout unloads the KeepAlive LaunchAgent,
        // preventing the process from immediately restarting.
        let target = "gui/" + String(getuid()) + "/" + agentLabel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [controller, "stop"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var stopped = false
            do {
                try task.run()
                task.waitUntilExit()
                stopped = task.terminationStatus == 0
            } catch {
                stopped = false
            }
            if !stopped {
                // Already stopped/unloaded is fine; never claim a complete
                // quit if the managed agent is still registered with launchd.
                let agentRemaining = self?.output("/bin/launchctl", ["print", target]) ?? ""
                let coreTarget = "gui/" + String(getuid()) + "/" + coreLabel
                let coreRemaining = self?.output("/bin/launchctl", ["print", coreTarget]) ?? ""
                stopped = agentRemaining.isEmpty && coreRemaining.isEmpty
            }
            DispatchQueue.main.async {
                if stopped {
                    NSApp.terminate(nil)
                } else {
                    self?.showNotice("Could not stop TapTether agent",
                        "The menu remains open because the background agent "
                        + "could not be stopped. Choose Stop agent and retry.")
                }
            }
        }
    }
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
        let token = value(after: "Pairing token (PRIVATE):", in: details)
        let fingerprint = value(after: "TLS SHA-256 fingerprint:", in: details)
        let alert = NSAlert()
        alert.messageText = "Private pairing details"
        alert.informativeText = "Select any text below, or use a copy button. Keep the token private."
        alert.alertStyle = .informational
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = details
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy token")
        alert.addButton(withTitle: "Copy fingerprint")
        alert.addButton(withTitle: "Copy all")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let copied: String?
        switch response {
        case .alertFirstButtonReturn: copied = token
        case .alertSecondButtonReturn: copied = fingerprint
        case .alertThirdButtonReturn: copied = details
        default: copied = nil
        }
        if let copied = copied, !copied.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
        }
    }

    private func value(after prefix: String, in details: String) -> String {
        for line in details.components(separatedBy: .newlines) where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
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
