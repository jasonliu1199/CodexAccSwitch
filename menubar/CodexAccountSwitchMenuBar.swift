import Cocoa
import CryptoKit

struct AccountState {
    let profiles: [String]
    let activeProfile: String?
    let authExists: Bool
}

enum AccountStoreError: LocalizedError {
    case invalidProfileName(String)
    case authNotFound(String)
    case profileNotFound(String)
    case profileAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfileName(let name):
            return "Invalid profile name: \(name). Allowed: letters, numbers, dot, underscore, dash."
        case .authNotFound(let path):
            return "Auth file not found: \(path)"
        case .profileNotFound(let name):
            return "Profile not found: \(name)"
        case .profileAlreadyExists(let name):
            return "Profile already exists: \(name)"
        }
    }
}

final class AccountStore {
    private let fileManager = FileManager.default

    private var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private var authFile: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    private var profileDir: URL {
        codexHome.appendingPathComponent("account-switch/profiles", isDirectory: true)
    }

    private var backupDir: URL {
        codexHome.appendingPathComponent("account-switch/backups", isDirectory: true)
    }

    func loadState() throws -> AccountState {
        try ensureDirs()
        let profiles = try listProfiles()
        let active = try currentActiveProfile(profiles: profiles)
        let authExists = fileManager.fileExists(atPath: authFile.path)
        return AccountState(profiles: profiles, activeProfile: active, authExists: authExists)
    }

    func saveCurrentAuth(as profileName: String) throws {
        try validateProfileName(profileName)
        try ensureDirs()
        guard fileManager.fileExists(atPath: authFile.path) else {
            throw AccountStoreError.authNotFound(authFile.path)
        }
        let target = profilePath(profileName)
        try fileManager.copyItem(at: authFile, to: target, replace: true)
        set600IfPossible(target)
    }

    func switchToProfile(_ profileName: String) throws {
        try validateProfileName(profileName)
        try ensureDirs()

        let source = profilePath(profileName)
        guard fileManager.fileExists(atPath: source.path) else {
            throw AccountStoreError.profileNotFound(profileName)
        }

        if fileManager.fileExists(atPath: authFile.path) {
            let timestamp = Self.backupDateFormatter.string(from: Date())
            let backup = backupDir.appendingPathComponent("auth-\(timestamp).json")
            try fileManager.copyItem(at: authFile, to: backup, replace: true)
            set600IfPossible(backup)
        } else {
            try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        }

        try fileManager.copyItem(at: source, to: authFile, replace: true)
        set600IfPossible(authFile)
    }

    func deleteProfile(_ profileName: String) throws {
        try validateProfileName(profileName)
        let target = profilePath(profileName)
        guard fileManager.fileExists(atPath: target.path) else {
            throw AccountStoreError.profileNotFound(profileName)
        }
        try fileManager.removeItem(at: target)
    }

    func openProfilesInFinder() {
        do {
            try ensureDirs()
            NSWorkspace.shared.activateFileViewerSelecting([profileDir])
        } catch {
            // Ignore UI helper failure.
        }
    }

    private func ensureDirs() throws {
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
    }

    private func listProfiles() throws -> [String] {
        guard fileManager.fileExists(atPath: profileDir.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: profileDir, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func currentActiveProfile(profiles: [String]) throws -> String? {
        guard fileManager.fileExists(atPath: authFile.path) else { return nil }
        let authHash = try hashForFile(at: authFile)
        for profile in profiles {
            let path = profilePath(profile)
            let profileHash = try hashForFile(at: path)
            if profileHash == authHash {
                return profile
            }
        }
        return nil
    }

    private func profilePath(_ profileName: String) -> URL {
        profileDir.appendingPathComponent("\(profileName).json")
    }

    private func validateProfileName(_ profileName: String) throws {
        let regex = try NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
        let range = NSRange(location: 0, length: profileName.utf16.count)
        let valid = regex.firstMatch(in: profileName, options: [], range: range) != nil
        if profileName.isEmpty || !valid {
            throw AccountStoreError.invalidProfileName(profileName)
        }
    }

    private func hashForFile(at fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func set600IfPossible(_ fileURL: URL) {
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private extension FileManager {
    func copyItem(at srcURL: URL, to dstURL: URL, replace: Bool) throws {
        if replace, fileExists(atPath: dstURL.path) {
            try removeItem(at: dstURL)
        }
        try copyItem(at: srcURL, to: dstURL)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RestartError: LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return message
            }
        }
    }

    private let store = AccountStore()
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var relaunchTimer: Timer?
    private var pendingRelaunchPaths = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        relaunchTimer?.invalidate()
        relaunchTimer = nil
    }

    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try store.switchToProfile(name)
            rebuildMenu()

            do {
                try restartCodexDesktop()
            } catch {
                showError("Switched to \(name), but failed to restart Codex automatically.\n\(error.localizedDescription)")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Delete profile '\(name)'?"
        alert.informativeText = "This removes the saved profile file. Active auth.json is not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            runAndRefresh {
                try store.deleteProfile(name)
            }
        }
    }

    @objc private func saveCurrentProfile(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Save Current Auth As"
        alert.informativeText = "Enter profile name (letters, numbers, dot, underscore, dash)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. work"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        runAndRefresh {
            try store.saveCurrentAuth(as: name)
        }
    }

    @objc private func refresh(_ sender: NSMenuItem) {
        rebuildMenu()
    }

    @objc private func openProfilesFolder(_ sender: NSMenuItem) {
        store.openProfilesInFinder()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func runAndRefresh(_ work: () throws -> Void) {
        do {
            try work()
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func restartCodexDesktop() throws {
        let runningTargets = codexRunningApplications()
        var relaunchPaths = Set<String>()
        for app in runningTargets {
            if let path = app.bundleURL?.path {
                relaunchPaths.insert(path)
            }
        }

        if runningTargets.isEmpty {
            try launchDefaultCodex()
            return
        }

        pendingRelaunchPaths = relaunchPaths
        for app in runningTargets {
            _ = app.terminate()
        }
        scheduleRelaunchWhenCodexFullyExits()
    }

    private func scheduleRelaunchWhenCodexFullyExits() {
        relaunchTimer?.invalidate()
        relaunchTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let stillRunning = !self.codexRunningApplications().isEmpty
            if stillRunning {
                return
            }

            timer.invalidate()
            self.relaunchTimer = nil
            let paths = self.pendingRelaunchPaths
            self.pendingRelaunchPaths.removeAll()

            do {
                if paths.isEmpty {
                    try self.launchDefaultCodex()
                } else {
                    for path in paths.sorted() {
                        try self.openApp(arguments: [path])
                    }
                }
            } catch {
                self.showError("Switched profile, but failed to reopen Codex automatically.\n\(error.localizedDescription)")
            }
        }
    }

    private func codexRunningApplications() -> [NSRunningApplication] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier

        return NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier == currentPID { return false }
            if let currentBundleID, app.bundleIdentifier == currentBundleID { return false }
            return isLikelyCodexApp(app)
        }
    }

    private func isLikelyCodexApp(_ app: NSRunningApplication) -> Bool {
        let name = app.localizedName?.lowercased() ?? ""
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let appFile = app.bundleURL?.lastPathComponent.lowercased() ?? ""

        if name == "codex" || appFile == "codex.app" {
            return true
        }
        if bundleID == "com.openai.codex" {
            return true
        }
        if bundleID.contains("codex"), !bundleID.contains("account-switch") {
            return true
        }
        if name.contains("codex"), !name.contains("account switch") {
            return true
        }
        return false
    }

    private func launchDefaultCodex() throws {
        do {
            try openApp(arguments: ["-a", "Codex"])
        } catch {
            throw RestartError.launchFailed(
                "Could not open the Codex app automatically. Please make sure 'Codex' is installed in /Applications."
            )
        }
    }

    private func openApp(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let argText = arguments.joined(separator: " ")
            throw RestartError.launchFailed("open \(argText) failed with exit code \(process.terminationStatus).")
        }
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        do {
            let state = try store.loadState()
            let title = titleForState(state)
            statusItem.button?.title = title
            statusItem.button?.image = nil

            let activeText = state.activeProfile.map { "Active: \($0)" } ?? {
                state.authExists ? "Active: (unmatched auth.json)" : "Active: (none)"
            }()
            let header = NSMenuItem(title: activeText, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            if state.profiles.isEmpty {
                let item = NSMenuItem(title: "No saved profiles", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for profile in state.profiles {
                    let item = NSMenuItem(
                        title: profile,
                        action: #selector(switchProfile(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = profile
                    item.state = (profile == state.activeProfile) ? .on : .off
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())

            let saveItem = NSMenuItem(title: "Save Current Auth As...", action: #selector(saveCurrentProfile(_:)), keyEquivalent: "s")
            saveItem.target = self
            menu.addItem(saveItem)

            let deleteParent = NSMenuItem(title: "Delete Profile", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            if state.profiles.isEmpty {
                let empty = NSMenuItem(title: "No saved profiles", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                deleteMenu.addItem(empty)
            } else {
                for profile in state.profiles {
                    let item = NSMenuItem(title: profile, action: #selector(deleteProfile(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile
                    deleteMenu.addItem(item)
                }
            }
            menu.setSubmenu(deleteMenu, for: deleteParent)
            menu.addItem(deleteParent)

            let openItem = NSMenuItem(title: "Open Profiles Folder", action: #selector(openProfilesFolder(_:)), keyEquivalent: "o")
            openItem.target = self
            menu.addItem(openItem)

            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        } catch {
            statusItem.button?.title = "Cdx?"
            let item = NSMenuItem(title: "Error: \(error.localizedDescription)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        }

        statusItem.menu = menu
    }

    private func titleForState(_ state: AccountState) -> String {
        if let active = state.activeProfile {
            return "Cdx:\(active)"
        }
        if state.authExists {
            return "Cdx:?"
        }
        return "Cdx:-"
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Codex Account Switch"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@main
final class CodexAccountSwitchMenuBarMain: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
