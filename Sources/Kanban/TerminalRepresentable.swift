import SwiftUI
import AppKit
import SwiftTerm

/// NSViewRepresentable wrapping SwiftTerm's LocalProcessTerminalView.
/// Connects to a tmux session or runs a shell command.
struct TerminalRepresentable: NSViewRepresentable {
    let command: String
    let arguments: [String]
    let currentDirectory: String?
    var onProcessExit: ((Int32) -> Void)?

    init(
        command: String = "/bin/zsh",
        arguments: [String] = [],
        currentDirectory: String? = nil,
        onProcessExit: ((Int32) -> Void)? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.onProcessExit = onProcessExit
    }

    /// Convenience: attach to a tmux session.
    static func tmuxAttach(sessionName: String, onExit: ((Int32) -> Void)? = nil) -> TerminalRepresentable {
        TerminalRepresentable(
            command: "/opt/homebrew/bin/tmux",
            arguments: ["attach-session", "-t", sessionName],
            onProcessExit: onExit
        )
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.caretColor = .systemGreen

        // Start the process
        terminal.startProcess(
            executable: command,
            args: arguments,
            environment: nil,
            execName: nil,
            currentDirectory: currentDirectory
        )

        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // SwiftTerm handles resize automatically via NSView layout
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExit: onProcessExit)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExit: ((Int32) -> Void)?

        init(onProcessExit: ((Int32) -> Void)?) {
            self.onProcessExit = onProcessExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm handles PTY resize internally
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            if let code = exitCode {
                onProcessExit?(code)
            }
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // Could update window title if needed
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Could track working directory changes
        }
    }
}
