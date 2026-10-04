import Foundation

/// Whether the work a task does is for the human at one of his devices.
/// A master sets it while it serves a request of a full-scope device, and
/// `RemoteClient` passes it on in a header, so the master that owns a card
/// can tell a request forwarded for the phone from the masters' own sync.
public enum RemoteActingFor {
    public static let header = "X-Kanban-For-Owner"

    @TaskLocal public static var owner = false
}
