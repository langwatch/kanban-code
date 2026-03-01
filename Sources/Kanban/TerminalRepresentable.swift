import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Terminal process cache

/// Caches tmux terminal views across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    private var terminals: [String: LocalProcessTerminalView] = [:]

    /// Resolved tmux binary path — checked once, reused for all terminals.
    private static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "tmux"
    }()

    /// Get or create a terminal for the given tmux session name.
    func terminal(for sessionName: String, frame: NSRect) -> LocalProcessTerminalView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = LocalProcessTerminalView(frame: frame)

        // Dark terminal colors matching a real terminal
        terminal.nativeBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0)
        terminal.caretColor = .systemGreen

        // Brighter ANSI palette (SwiftTerm Color uses UInt16 0-65535, multiply 0-255 by 257)
        let c = { (r: UInt16, g: UInt16, b: UInt16) in SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
        terminal.installColors([
            // Standard colors (0-7)
            c(0x33, 0x33, 0x33),  // black (slightly visible)
            c(0xFF, 0x5F, 0x56),  // red
            c(0x5A, 0xF7, 0x8E),  // green
            c(0xFF, 0xD7, 0x5F),  // yellow
            c(0x57, 0xAC, 0xFF),  // blue
            c(0xFF, 0x6A, 0xC1),  // magenta
            c(0x5A, 0xF7, 0xD4),  // cyan
            c(0xE0, 0xE0, 0xE0),  // white
            // Bright colors (8-15)
            c(0x66, 0x66, 0x66),  // bright black
            c(0xFF, 0x6E, 0x67),  // bright red
            c(0x5A, 0xF7, 0x8E),  // bright green
            c(0xFF, 0xFC, 0x67),  // bright yellow
            c(0x6B, 0xC1, 0xFF),  // bright blue
            c(0xFF, 0x77, 0xD0),  // bright magenta
            c(0x5A, 0xF7, 0xD4),  // bright cyan
            c(0xFF, 0xFF, 0xFF),  // bright white
        ])

        terminal.autoresizingMask = [.width, .height]
        terminal.isHidden = true
        // Wait for the tmux session to exist before attaching.
        // The .createTmuxSession effect runs async — the session may not
        // exist yet when the UI renders the terminal tab.
        // Use user's login shell for their env, plus full tmux path since
        // GUI apps don't inherit Homebrew PATH.
        let escaped = sessionName.replacingOccurrences(of: "'", with: "'\\''")
        let tmux = Self.tmuxPath
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: userShell,
            args: ["-l", "-c", "for i in $(seq 1 50); do '\(tmux)' has-session -t '\(escaped)' 2>/dev/null && break; sleep 0.1; done; exec '\(tmux)' attach-session -t '\(escaped)'"],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
        terminals[sessionName] = terminal
        return terminal
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    func remove(_ sessionName: String) {
        if let terminal = terminals.removeValue(forKey: sessionName) {
            terminal.removeFromSuperview()
            terminal.terminate()
        }
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String

    func makeNSView(context: Context) -> TerminalContainerNSView {
        let container = TerminalContainerNSView()
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        // Add any new sessions (idempotent — reuses cached terminals)
        for session in sessions {
            nsView.ensureTerminal(for: session)
        }
        // Remove terminals that are no longer in the list
        nsView.removeTerminalsNotIn(Set(sessions))
        // Switch visible terminal
        nsView.showTerminal(for: activeSession)
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
        // Detach terminals from this container but do NOT terminate them.
        // They live on in TerminalCache and will be reparented when the drawer reopens.
        nsView.detachAll()
    }
}

/// AppKit container that owns multiple LocalProcessTerminalView instances.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    private static let terminalPadding: CGFloat = 6

    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    private var activeSession: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        // Reparent: remove from any previous superview and add to this container
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        terminal.frame = bounds
        terminal.isHidden = true
        managedSessions.append(sessionName)
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String) {
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            let isActive = (name == sessionName)
            terminal.isHidden = !isActive
            if isActive {
                // Grab keyboard focus so the user can type immediately
                window?.makeFirstResponder(terminal)
            }
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    /// This is called when sessions are killed — terminals are fully terminated.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    /// Called when the drawer closes — terminals survive in TerminalCache.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
        for sub in subviews {
            sub.frame = inset
        }
    }
}
