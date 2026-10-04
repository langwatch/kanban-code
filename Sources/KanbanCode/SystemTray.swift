import SwiftUI
import AppKit
import KanbanCodeCore

private let systemTrayLogDir: String = {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

/// Manages the menu bar status item (system tray).
/// Shows session icon when Claude sessions are actively working.
/// Launches a helper .app so tools like Amphetamine can detect active sessions.
@MainActor
final class SystemTray: NSObject, @unchecked Sendable {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var store: BoardStore?
    private var activeSessionApp: NSRunningApplication?
    /// Fallback for dev mode (bare binary, no .app bundle).
    private var activeSessionProcess: Process?
    /// Time when In Progress last had sessions (for linger timeout).
    private var lastActiveTime: Date?
    private var lastLocalActiveTime: Date?
    /// Timer for live-updating the countdown while menu is open.
    private var countdownTimer: Timer?
    /// Reference to the countdown menu item for live updates.
    private weak var countdownItem: NSMenuItem?

    private static let activeSessionBundleID = "com.kanban-code.active-session"

    /// How long to keep tray visible after last active session.
    /// Reads from UserDefaults (synced with @AppStorage("sessionLingerTimeout") in settings).
    private var lingerTimeout: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "sessionLingerTimeout")
        return stored > 0 ? stored : 60
    }

    func setup(store: BoardStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build icon with 1x + 2x representations for crisp rendering at 22x22pt
        // (same approach as cc-amphetamine's Electron nativeImage)
        let icon = NSImage(size: NSSize(width: 22, height: 22))
        var hasReps = false

        if let url = Bundle.appResources.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22)
            icon.addRepresentation(rep)
            hasReps = true
        }
        if let url = Bundle.appResources.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources"),
           let rep = NSImageRep(contentsOf: url) {
            rep.size = NSSize(width: 22, height: 22) // same logical size; 44px used on retina
            icon.addRepresentation(rep)
            hasReps = true
        }

        if hasReps {
            icon.isTemplate = true
            statusItem?.button?.image = icon
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kanban")
        }

        updateMenu()
        updateVisibility()
    }

    func update() {
        updateMenu()
        updateVisibility()
    }

    private func updateMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if let store {
            let activeCards = store.state.cards(in: .inProgress)
            let attentionCards = store.state.cards(in: .waiting)

            // Countdown at the top when lingering (no active sessions)
            if activeCards.isEmpty {
                let item = NSMenuItem(title: countdownText(), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                countdownItem = item
                if !attentionCards.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
            }

            if !activeCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "In Progress"))
                for card in activeCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    if card.isActivelyWorking {
                        item.image = NSImage(systemSymbolName: "gear.circle.fill", accessibilityDescription: nil)
                    } else {
                        item.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
                    }
                    menu.addItem(item)
                }
            }

            if !attentionCards.isEmpty {
                menu.addItem(NSMenuItem.sectionHeader(title: "Waiting"))
                for card in attentionCards.prefix(5) {
                    let item = NSMenuItem(title: card.displayTitle, action: nil, keyEquivalent: "")
                    item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Kanban", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    private func countdownText() -> String {
        guard let lastActive = lastActiveTime else {
            return "No active sessions"
        }
        let elapsed = Date().timeIntervalSince(lastActive)
        let remaining = max(0, Int(lingerTimeout - elapsed))
        let mins = remaining / 60
        let secs = remaining % 60
        let countdown = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        return "No active sessions, sleeping in \(countdown)"
    }

    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Show tray icon when there are In Progress sessions, or within linger timeout.
    /// Also manages the active-session helper app for Amphetamine integration.
    /// The tray icon shows any active session; the helper only runs for
    /// sessions on this Mac, so cards on a boxd machine never keep it awake,
    /// and while a card here is in use from another device (`RemoteWakeHold`).
    private func updateVisibility() {
        guard let store else { return }
        let hasActive = store.state.cardCount(in: .inProgress) > 0
        let hasLocalActive = store.state.hasLocalActiveCards

        if hasActive {
            lastActiveTime = Date()
            statusItem?.isVisible = true
        } else if let lastActive = lastActiveTime,
                  Date().timeIntervalSince(lastActive) < lingerTimeout {
            // Linger: keep visible for a bit after last active session
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }

        // A card in use from the phone counts like a working session.
        if hasLocalActive || RemoteWakeHold.shared.isHolding() {
            lastLocalActiveTime = Date()
            startActiveSessionIfNeeded()
        } else if let lastLocal = lastLocalActiveTime,
                  Date().timeIntervalSince(lastLocal) < lingerTimeout {
            // Keep the helper running during the linger window.
        } else {
            stopActiveSession()
        }
    }

    // MARK: - Active session helper app (for Amphetamine)

    /// Launches the active-session helper .app so tools like Amphetamine can detect it.
    /// Falls back to bare binary for development.
    private func startActiveSessionIfNeeded() {
        // Already running via .app?
        if let app = activeSessionApp, !app.isTerminated { return }
        // Already running via bare binary?
        if let proc = activeSessionProcess, proc.isRunning { return }
        // Check if already running from a previous app launch
        if let existing = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.activeSessionBundleID }) {
            activeSessionApp = existing
            MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [existing.processIdentifier])
            Self.log("active-session already running: pid=\(existing.processIdentifier)")
            return
        }

        // Try .app bundle first (Amphetamine can detect this)
        if let appURL = Self.findActiveSessionApp() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
                Task { @MainActor in
                    if let error {
                        Self.log("active-session app failed to start: \(error)")
                    } else if let app {
                        self?.activeSessionApp = app
                        MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [app.processIdentifier])
                        Self.log("active-session started: pid=\(app.processIdentifier)")
                    }
                }
            }
            return
        }

        // Fallback: bare binary (dev mode — no Amphetamine support)
        if let path = Self.findActiveSessionBinary() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.qualityOfService = .background
            proc.terminationHandler = { process in
                let reason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
                Self.log("active-session terminated: status=\(process.terminationStatus) reason=\(reason)")
            }
            do {
                try proc.run()
                activeSessionProcess = proc
                MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [proc.processIdentifier])
                Self.log("active-session started (bare binary): pid=\(proc.processIdentifier)")
            } catch {
                Self.log("active-session failed to start: \(error)")
            }
            return
        }

        Self.log("active-session not found")
    }

    /// Stop the active-session helper when no more active sessions.
    /// Also discovers and kills orphaned processes from previous app instances.
    private func stopActiveSession() {
        var helperPIDs: [pid_t?] = []

        if let app = activeSessionApp, !app.isTerminated {
            helperPIDs.append(app.processIdentifier)
        }
        activeSessionApp = nil

        if let proc = activeSessionProcess, proc.isRunning {
            helperPIDs.append(proc.processIdentifier)
        }
        activeSessionProcess = nil

        // Collect orphaned helpers from previous app instances before signaling any
        // process. LaunchServices can temporarily report a helper after SIGTERM, so
        // using NSRunningApplication.terminate() here can send an AppleEvent through
        // a stale application port and crash inside AE.framework.
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == Self.activeSessionBundleID && !app.isTerminated {
            helperPIDs.append(app.processIdentifier)
        }

        for pid in Self.uniqueActiveSessionPIDs(helperPIDs) {
            Self.log("stopping active-session: pid=\(pid)")
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        MemoryDiagnostics.shared.setRelatedProcessPIDs(label: "active-session", pids: [])
    }

    nonisolated static func uniqueActiveSessionPIDs(_ candidates: [pid_t?]) -> Set<pid_t> {
        Set(candidates.compactMap { pid in
            guard let pid, pid > 0 else { return nil }
            return pid
        })
    }

    // MARK: - Logging

    nonisolated static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logPath = (systemTrayLogDir as NSString).appendingPathComponent("kanban.log")
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
        }
    }

    /// Find the active-session .app bundle.
    private static func findActiveSessionApp() -> URL? {
        var candidates: [String] = []

        // 1. Inside main app bundle: KanbanCode.app/Contents/Helpers/kanban-code-active-session.app
        candidates.append(
            (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Helpers/kanban-code-active-session.app")
        )

        // 2. Next to the main app bundle
        candidates.append(
            ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("kanban-code-active-session.app")
        )

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                log("active-session app found at: \(candidate)")
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    /// Find the bare active-session binary (fallback for development).
    private static func findActiveSessionBinary() -> String? {
        var candidates: [String] = []

        // 1. Next to the running Kanban binary (swift run, .app bundle)
        let kanbanPath = ProcessInfo.processInfo.arguments[0]
        let dir = (kanbanPath as NSString).deletingLastPathComponent
        candidates.append((dir as NSString).appendingPathComponent("kanban-code-active-session"))

        // 2. Inside .app bundle's MacOS directory
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            candidates.append((bundleDir as NSString).appendingPathComponent("kanban-code-active-session"))
        }

        // 3. ~/.kanban-code/bin/kanban-code-active-session for installed locations
        candidates.append(
            (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/bin/kanban-code-active-session")
        )

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                log("active-session found at: \(candidate)")
                return candidate
            }
        }

        log("active-session binary not found, searched: \(candidates)")
        return nil
    }
}

// MARK: - NSMenuDelegate (live countdown)

extension SystemTray: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            guard countdownItem != nil else { return }
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.countdownItem?.title = self?.countdownText() ?? ""
                }
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }
}
