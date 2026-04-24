import SwiftUI
import AppKit
import UserNotifications
import KanbanCodeCore

@main
struct KanbanCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        MainThreadWatchdog.shared.start()
        ChatBootstrap.run()
    }

    var body: some Scene {
        Window("Kanban Code", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    NotificationCenter.default.post(name: .kanbanCodeNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Search Sessions") {
                    NotificationCenter.default.post(name: .kanbanCodeToggleSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    Self.adjustZoom(by: 1)
                }
                .keyboardShortcut("+", modifiers: .command)

                // Cmd+= (without shift) also zooms in — standard macOS behavior
                Button("Zoom In") {
                    Self.adjustZoom(by: 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    Self.adjustZoom(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    UserDefaults.standard.set(1, forKey: "uiTextSize")
                    UserDefaults.standard.set(Double(TerminalCache.defaultFontSize), forKey: TerminalCache.fontSizeKey)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// Adjust both UI text size and session detail font size together.
    private static func adjustZoom(by delta: Int) {
        let currentUI = UserDefaults.standard.object(forKey: "uiTextSize") != nil
            ? UserDefaults.standard.integer(forKey: "uiTextSize") : 1
        UserDefaults.standard.set(min(max(currentUI + delta, 0), 4), forKey: "uiTextSize")

        let termSize = UserDefaults.standard.double(forKey: TerminalCache.fontSizeKey)
        let currentTerm = termSize > 0 ? termSize : Double(TerminalCache.defaultFontSize)
        UserDefaults.standard.set(min(max(currentTerm + Double(delta), 8), 24), forKey: TerminalCache.fontSizeKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS smart substitutions app-wide (smart quotes, dashes, autocorrect).
        // These break code input by replacing -- with em-dash, " with curly quotes, etc.
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "NSAutomaticDashSubstitutionEnabled")
        defaults.set(false, forKey: "NSAutomaticTextReplacementEnabled")
        defaults.set(false, forKey: "NSAutomaticSpellingCorrectionEnabled")
        defaults.set(false, forKey: "NSAutomaticTextCompletionEnabled")
        defaults.set(false, forKey: "NSAutomaticCapitalizationEnabled")
        defaults.set(false, forKey: "NSAutomaticPeriodSubstitutionEnabled")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.delegate = self
        }

        // Set app icon from bundled resource (SPM uses Bundle.appResources)
        if let iconURL = Bundle.appResources.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "Resources"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Install `kanban` CLI to ~/.local/bin
        Self.installCLI()

        // UNUserNotificationCenter requires a bundle identifier — skip when running via `swift run`
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    print("[Kanban Code] Notification permission error: \(error)")
                } else if !granted {
                    print("[Kanban Code] Notification permission denied")
                }
            }
        }
    }

    /// Install a `kanban` shell script to ~/.local/bin that delegates to the
    /// TypeScript CLI bundled inside the app at Contents/Resources/cli/dist/kanban.js.
    private static func installCLI() {
        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
        let scriptPath = binDir.appendingPathComponent("kanban")

        guard let resourceURL = Bundle.main.resourceURL else {
            print("[Kanban Code] Cannot install CLI: no resource URL")
            return
        }
        let cliPath = resourceURL.appendingPathComponent("cli/dist/kanban.js").path

        guard FileManager.default.fileExists(atPath: cliPath) else {
            print("[Kanban Code] Cannot install CLI: \(cliPath) not found")
            return
        }

        let script = """
        #!/bin/sh
        # Installed by Kanban Code — TypeScript CLI wrapper.
        exec node "\(cliPath)" "$@"
        """
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
            )
        } catch {
            print("[Kanban Code] Failed to install CLI: \(error)")
        }
    }

    /// Check for a pending project open request from the CLI.
    func applicationDidBecomeActive(_ notification: Notification) {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kanban-code/open-project")
        guard let path = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        NotificationCenter.default.post(
            name: .kanbanCodeOpenProject, object: nil,
            userInfo: ["path": path]
        )
    }

    /// Prevent Cmd+W from closing the single window — close terminal tab instead.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .kanbanCloseTerminalTab, object: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Post notification — ContentView checks store state for managed sessions
        NotificationCenter.default.post(name: .kanbanCodeQuitRequested, object: nil)
        return .terminateLater
    }

    /// Synchronous tmux list-sessions — returns all sessions (no filtering).
    static func listAllTmuxSessionsSync() -> [TmuxSession] {
        let tmuxPath = ShellCommand.findExecutable("tmux") ?? "tmux"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return TmuxSession(name: parts[0], path: parts[1], attached: parts[2] == "1")
        }
    }

    static func killTmuxSessionSync(name: String) {
        let tmuxPath = ShellCommand.findExecutable("tmux") ?? "tmux"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["kill-session", "-t", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // Handle kanbancode:// deep links (from Pushover tap, browser, CLI, etc.)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "kanbancode" else { continue }
            // kanbancode://card/{cardId}
            if url.host == "card",
               let cardId = url.pathComponents.dropFirst().first, !cardId.isEmpty {
                NotificationCenter.default.post(
                    name: .kanbanCodeSelectCard, object: nil,
                    userInfo: ["cardId": cardId]
                )
            }
            // kanbancode://open?path=/some/project
            if url.host == "open",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
               !path.isEmpty {
                NotificationCenter.default.post(
                    name: .kanbanCodeOpenProject, object: nil,
                    userInfo: ["path": path]
                )
            }
            // kanbancode://channel/<name> — from `kanban channel open <name>` CLI.
            if url.host == "channel",
               let name = url.pathComponents.dropFirst().first, !name.isEmpty {
                let normalized = name.hasPrefix("#") ? String(name.dropFirst()) : name
                NotificationCenter.default.post(
                    name: .kanbanCodeSelectChannel, object: nil,
                    userInfo: ["channelName": normalized]
                )
            }
            // kanbancode://dm/<handle> or ?handle=<h>&cardId=<c>
            if url.host == "dm" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let pathHandle = url.pathComponents.dropFirst().first
                let queryHandle = components?.queryItems?.first(where: { $0.name == "handle" })?.value
                let cardId = components?.queryItems?.first(where: { $0.name == "cardId" })?.value
                if let handle = (queryHandle?.isEmpty == false ? queryHandle : pathHandle),
                   !handle.isEmpty {
                    var info: [String: String] = ["handle": handle.hasPrefix("@") ? String(handle.dropFirst()) : handle]
                    if let cardId, !cardId.isEmpty { info["cardId"] = cardId }
                    NotificationCenter.default.post(
                        name: .kanbanCodeSelectDM, object: nil, userInfo: info
                    )
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle notification click — open app and route to the right drawer.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let cardId = info["cardId"] as? String {
            NotificationCenter.default.post(name: .kanbanCodeSelectCard, object: nil, userInfo: ["cardId": cardId])
        } else if let kind = info["chatKind"] as? String {
            switch kind {
            case "channel":
                if let name = info["channelName"] as? String {
                    NotificationCenter.default.post(
                        name: .kanbanCodeSelectChannel, object: nil,
                        userInfo: ["channelName": name]
                    )
                }
            case "dm":
                if let handle = info["dmHandle"] as? String {
                    NotificationCenter.default.post(
                        name: .kanbanCodeSelectDM, object: nil,
                        userInfo: ["dmHandle": handle]
                    )
                }
            default:
                break
            }
        }
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let kanbanCodeSelectChannel = Notification.Name("kanbanCodeSelectChannel")
    static let kanbanCodeSelectDM = Notification.Name("kanbanCodeSelectDM")
}


enum AppearanceMode: String, CaseIterable {
    case auto, light, dark

    var next: AppearanceMode {
        switch self {
        case .auto: .dark
        case .dark: .light
        case .light: .auto
        }
    }

    var icon: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var helpText: String {
        switch self {
        case .auto: "Appearance: Auto (click for Dark)"
        case .dark: "Appearance: Dark (click for Light)"
        case .light: "Appearance: Light (click for Auto)"
        }
    }
}

extension Notification.Name {
    static let kanbanCodeNewTask = Notification.Name("kanbanCodeNewTask")
    static let kanbanCodeToggleSearch = Notification.Name("kanbanCodeToggleSearch")
    static let kanbanCodeHookEvent = Notification.Name("kanbanCodeHookEvent")
    static let kanbanCodeHistoryChanged = Notification.Name("kanbanCodeHistoryChanged")
    static let kanbanCodeSettingsChanged = Notification.Name("kanbanCodeSettingsChanged")
    static let kanbanCodeSelectCard = Notification.Name("kanbanCodeSelectCard")
    static let kanbanCodeQuitRequested = Notification.Name("kanbanCodeQuitRequested")
    static let kanbanCodePromptFocusChanged = Notification.Name("kanbanCodePromptFocusChanged")
    static let kanbanSelectTerminalTab = Notification.Name("kanbanSelectTerminalTab")
    static let kanbanCloseTerminalTab = Notification.Name("kanbanCloseTerminalTab")
    static let chatCardExpanded = Notification.Name("chatCardExpanded")
    static let kanbanCodeAddLink = Notification.Name("kanbanCodeAddLink")
    static let kanbanCodeOpenProject = Notification.Name("kanbanCodeOpenProject")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserReload = Notification.Name("browserReload")
    static let kanbanReopenClosedTab = Notification.Name("kanbanReopenClosedTab")
}
