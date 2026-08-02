import SwiftUI
import AppKit
import UserNotifications
import KanbanCodeCore

@main
struct KanbanCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        MainThreadWatchdog.shared.start()
        MemoryDiagnostics.shared.start()
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

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    Self.performTextUndo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    Self.performTextRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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

    /// Keep Cmd+Z scoped to the focused text editor.
    ///
    /// AppKit's default Undo menu uses the window undo manager. SwiftUI can tear
    /// down custom NSTextViews while old text undo operations remain registered
    /// there, so an accidental Cmd+Z in the terminal can replay a stale
    /// `_undoRedoTextOperation:` target and crash. Text inputs still get normal
    /// undo/redo through their own active NSTextView undo manager.
    private static func performTextUndo() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.undoManager?.canUndo == true else { return }
        textView.undoManager?.undo()
    }

    private static func performTextRedo() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.undoManager?.canRedo == true else { return }
        textView.undoManager?.redo()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var terminationReplyPending = false
    private var quitConfirmationPanel: NSPanel?
    private weak var channelShareController: ChannelShareController?

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

    /// On activation, drain any pending CLI/gateway requests left as marker
    /// files in ~/.kanban-code. Plain files, not deep links, so they never
    /// relaunch the app (which would trip the quit-protection dialog).
    func applicationDidBecomeActive(_ notification: Notification) {
        checkPendingOpenProject()
        checkPendingFocusChannel()
    }

    /// Check for a pending project open request from the CLI.
    private func checkPendingOpenProject() {
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

    /// Check for a pending channel-focus request: select the channel the
    /// gateway wrote to ~/.kanban-code/focus-channel when a room spawned, so
    /// the board snaps to the room's channel without a relaunching deep link.
    private func checkPendingFocusChannel() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kanban-code/focus-channel")
        guard let raw = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        let name = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        NotificationCenter.default.post(
            name: .kanbanCodeSelectChannel, object: nil,
            userInfo: ["channelName": name]
        )
    }

    /// Prevent Cmd+W from closing the single window — close terminal tab instead.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .kanbanCloseTerminalTab, object: nil)
        return false
    }

    func register(channelShareController: ChannelShareController) {
        self.channelShareController = channelShareController
    }

    func applicationWillTerminate(_ notification: Notification) {
        channelShareController?.terminateAllImmediately()
    }

    /// Kanban Code keeps running from the system tray with its managed tmux
    /// sessions alive, so closing the last window must never start a quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        let managedSessions = Self.listManagedTmuxSessionsSync()
        KanbanCodeLog.info("quit", "Resolved \(managedSessions.count) live managed tmux session(s)")
        guard !managedSessions.isEmpty else { return .terminateNow }

        terminationReplyPending = true
        KanbanCodeLog.info("quit", "Termination requested; deferring for managed-session confirmation")

        // Enter deferred termination first, then present the AppKit-owned
        // sheet. The quit decision must not depend on SwiftUI view lifetime:
        // ContentView is already being torn down while AppKit waits here.
        DispatchQueue.main.async { [weak self] in
            guard self?.terminationReplyPending == true else { return }
            self?.presentQuitConfirmation(managedSessions: managedSessions)
        }
        return .terminateLater
    }

    @MainActor
    func replyToTermination(_ shouldTerminate: Bool) {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        KanbanCodeLog.info("quit", "Replying to termination: \(shouldTerminate)")
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    @MainActor
    private func presentQuitConfirmation(managedSessions: [TmuxSession]) {
        guard quitConfirmationPanel == nil else { return }

        let rows = Self.quitConfirmationRows(for: managedSessions)
        let view = QuitConfirmationView(
            sessions: rows,
            killManagedSessions: UserDefaults.standard.bool(forKey: "killTmuxOnQuit"),
            onCancel: { [weak self] in
                self?.finishQuitConfirmation(
                    shouldTerminate: false,
                    killManagedSessions: false,
                    managedSessions: managedSessions
                )
            },
            onQuit: { [weak self] shouldKill in
                self?.finishQuitConfirmation(
                    shouldTerminate: true,
                    killManagedSessions: shouldKill,
                    managedSessions: managedSessions
                )
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: view)
        quitConfirmationPanel = panel

        NSApp.activate(ignoringOtherApps: true)
        if let parent = Self.quitConfirmationParentWindow(excluding: panel) {
            parent.beginSheet(panel)
        } else {
            // The main window should normally exist, but retain an AppKit-owned
            // fallback so a quit decision is always visible.
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private func finishQuitConfirmation(
        shouldTerminate: Bool,
        killManagedSessions: Bool,
        managedSessions: [TmuxSession]
    ) {
        dismissQuitConfirmation()

        guard shouldTerminate else {
            replyToTermination(false)
            return
        }

        UserDefaults.standard.set(killManagedSessions, forKey: "killTmuxOnQuit")
        if killManagedSessions {
            let sessionNames = Set(managedSessions.map(\.name))
            for sessionName in sessionNames {
                Self.killTmuxSessionSync(name: sessionName)
            }
            CoordinationStore.clearTmuxSessionsSnapshot(sessionNames)
        }
        replyToTermination(true)
    }

    @MainActor
    private func dismissQuitConfirmation() {
        guard let panel = quitConfirmationPanel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        quitConfirmationPanel = nil
    }

    @MainActor
    private static func quitConfirmationParentWindow(excluding panel: NSPanel) -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow !== panel {
            return mainWindow
        }
        return NSApp.windows.first { window in
            window !== panel && window.isVisible && window.canBecomeMain
        }
    }

    static func quitConfirmationRows(for managedSessions: [TmuxSession]) -> [QuitConfirmationSession] {
        let links = CoordinationStore.readLinksSnapshot()
        return managedSessions.map { session in
            let cardTitle = links.first { link in
                link.tmuxLink?.allSessionNames.contains(session.name) == true
            }.map { link in
                KanbanCodeCard(link: link).displayTitle
            }
            return QuitConfirmationSession(session: session, cardTitle: cardTitle)
        }
    }

    /// Synchronous tmux list-sessions — returns all sessions (no filtering).
    ///
    /// `applicationShouldTerminate` must answer AppKit synchronously, so this
    /// runs on the main thread. A wedged tmux server would otherwise freeze the
    /// whole app there, so the wait is bounded and the child is killed on
    /// timeout. Output is drained before waiting to avoid a full-pipe deadlock.
    static func listAllTmuxSessionsSync(timeout: TimeInterval = 5) -> [TmuxSession] {
        let tmuxPath = ShellCommand.findExecutable("tmux") ?? "tmux"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }

        let collected = SyncProcessOutput()
        let finished = DispatchSemaphore(value: 0)
        let readHandle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            collected.store(readHandle.readDataToEndOfFile())
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            KanbanCodeLog.warn("quit", "tmux list-sessions timed out after \(Int(timeout))s")
            process.terminate()
            return []
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return [] }
        guard let output = String(data: collected.data, encoding: .utf8), !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return TmuxSession(name: parts[0], path: parts[1], attached: parts[2] == "1")
        }
    }

    static func listManagedTmuxSessionsSync() -> [TmuxSession] {
        let managedNames = Set(
            CoordinationStore.readLinksSnapshot()
                .flatMap { $0.tmuxLink?.allSessionNames ?? [] }
        )
        guard !managedNames.isEmpty else { return [] }
        return listAllTmuxSessionsSync()
            .filter { managedNames.contains($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        var shouldActivate = false
        for url in urls {
            guard url.scheme == "kanbancode" else { continue }
            // kanbancode://card/{cardId}
            if url.host == "card",
               let cardId = url.pathComponents.dropFirst().first, !cardId.isEmpty {
                shouldActivate = true
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
                shouldActivate = true
                NotificationCenter.default.post(
                    name: .kanbanCodeOpenProject, object: nil,
                    userInfo: ["path": path]
                )
            }
            // kanbancode://channel/<name> — from `kanban channel open <name>` CLI.
            if url.host == "channel",
               let name = url.pathComponents.dropFirst().first, !name.isEmpty {
                shouldActivate = true
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
                    shouldActivate = true
                    var info: [String: String] = ["handle": handle.hasPrefix("@") ? String(handle.dropFirst()) : handle]
                    if let cardId, !cardId.isEmpty { info["cardId"] = cardId }
                    NotificationCenter.default.post(
                        name: .kanbanCodeSelectDM, object: nil, userInfo: info
                    )
                }
            }
            // kanbancode://command/<id> from the CLI command mailbox.
            if url.host == "command",
               let requestId = url.pathComponents.dropFirst().first,
               !requestId.isEmpty {
                NotificationCenter.default.post(
                    name: .kanbanCodeCLICommand,
                    object: nil,
                    userInfo: ["requestId": requestId]
                )
            }
        }
        if shouldActivate {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
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
    static let kanbanCodePromptFocusChanged = Notification.Name("kanbanCodePromptFocusChanged")
    static let kanbanSelectTerminalTab = Notification.Name("kanbanSelectTerminalTab")
    static let kanbanCloseTerminalTab = Notification.Name("kanbanCloseTerminalTab")
    static let chatCardExpanded = Notification.Name("chatCardExpanded")
    static let kanbanCodeAddLink = Notification.Name("kanbanCodeAddLink")
    static let kanbanCodeOpenProject = Notification.Name("kanbanCodeOpenProject")
    static let kanbanCodeCLICommand = Notification.Name("kanbanCodeCLICommand")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserReload = Notification.Name("browserReload")
    static let kanbanReopenClosedTab = Notification.Name("kanbanReopenClosedTab")
}

/// Lock-protected box so a bounded synchronous process read can hand its output
/// back from a background queue.
private final class SyncProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func store(_ data: Data) {
        lock.lock()
        buffer = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
