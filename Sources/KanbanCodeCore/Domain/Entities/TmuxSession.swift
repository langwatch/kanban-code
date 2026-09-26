import Foundation

/// A tmux session discovered via `tmux list-sessions`.
public struct TmuxSession: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let path: String // session_path
    public let attached: Bool
    /// An agtop host's queued messages; nil for tmux sessions.
    public let agtopQueue: [String]?

    public init(name: String, path: String, attached: Bool = false, agtopQueue: [String]? = nil) {
        self.name = name
        self.path = path
        self.attached = attached
        self.agtopQueue = agtopQueue
    }
}
