import Foundation

/// What a process of this user carries in the environment it started with.
public enum ProcessEnvironment {
    /// What one variable of a process holds.
    public enum Reading: Equatable, Sendable {
        /// The environment could not be read: the process is gone or
        /// belongs to another user.
        case unreadable
        /// The environment was read and has no such variable.
        case absent
        case value(String)
    }

    /// The variable `name` of process `pid`: `/proc/<pid>/environ` on Linux,
    /// `ps eww` on macOS.
    public static func read(_ name: String, pid: Int) async -> Reading {
        #if os(Linux)
        guard let text = VaultCallerResolver.readProcFile("/proc/\(pid)/environ") else { return .unreadable }
        return parseEnviron(text, name: name)
        #else
        let ps = ShellCommand.findExecutable("ps") ?? "/bin/ps"
        guard let result = try? await ShellCommand.run(ps, arguments: ["eww", "-o", "command=", "-p", String(pid)]),
              result.succeeded else { return .unreadable }
        return parsePsEnvironment(result.stdout, name: name)
        #endif
    }

    /// `/proc/<pid>/environ`: NUL-separated `KEY=value` entries. An empty
    /// file is a process the reader may not see into.
    public static func parseEnviron(_ text: String, name: String) -> Reading {
        let entries = text.split(separator: "\0", omittingEmptySubsequences: true)
        guard !entries.isEmpty else { return .unreadable }
        let prefix = name + "="
        guard let entry = entries.first(where: { $0.hasPrefix(prefix) }) else { return .absent }
        return .value(String(entry.dropFirst(prefix.count)))
    }

    /// `ps eww -o command=`: the command line, then the environment as
    /// space-separated `KEY=value` words. ps prints no environment for a
    /// process of another user, which then reads as unreadable (no `PATH`).
    public static func parsePsEnvironment(_ output: String, name: String) -> Reading {
        let words = output.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard words.contains(where: { $0.hasPrefix("PATH=") || $0.hasPrefix("HOME=") }) else { return .unreadable }
        let prefix = name + "="
        guard let word = words.last(where: { $0.hasPrefix(prefix) }) else { return .absent }
        return .value(String(word.dropFirst(prefix.count)))
    }
}
