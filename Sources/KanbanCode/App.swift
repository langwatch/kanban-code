import SwiftUI
import AppKit
import UserNotifications
import KanbanCodeCore

@main
struct KanbanCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        MainThreadWatchdog.shared.start()
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

        // Set up notifications: delegate must be set BEFORE requesting authorization
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

    // Handle kanbancode:// deep links (from Pushover tap, browser, etc.)
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

    // Handle notification click — open app and select the card
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let cardId = response.notification.request.content.userInfo["cardId"] as? String {
            NotificationCenter.default.post(name: .kanbanCodeSelectCard, object: nil, userInfo: ["cardId": cardId])
        }
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
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
}
