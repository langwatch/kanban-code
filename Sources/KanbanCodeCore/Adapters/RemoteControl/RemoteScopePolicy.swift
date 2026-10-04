import Foundation
import KanbanCodeRemoteKit

/// What the narrow scopes may call. `full` and `agent` are checked route by
/// route in the server; `peer` and `terminal` are allow lists, so a route
/// added later is refused for them until it is listed here.
enum RemoteScopePolicy {
    /// A route as the lists name it: `cards/search`, `cards/*/queue/*`, `attention/*/resolve`,
    /// `channels/files`, `vault/replica`.
    static func shape(_ rest: [String]) -> String {
        guard let first = rest.first else { return "" }
        switch first {
        case "cards":
            if rest == ["cards", "search"] { return "cards/search" }
            return rest.enumerated().map { item in
                item.offset == 1 || (item.offset == 3 && (rest[2] == "queue" || rest[2] == "side-chat")) ? "*" : item.element
            }.joined(separator: "/")
        case "attention":
            if rest.count == 3 { return "attention/*/\(rest[2])" }
            return rest.joined(separator: "/")
        case "channels":
            return rest.prefix(2).joined(separator: "/")
        default:
            return rest.joined(separator: "/")
        }
    }

    /// What a paired master calls on its peer: card sync, forwarding of what
    /// the human does to a card the peer owns, moves between masters,
    /// approvals, channels, agent sync, the vault replica and the scrubber.
    /// No terminal, and no vault route that asks for or edits a secret.
    static let peer: Set<String> = [
        "GET me", "GET board", "GET machines", "GET events", "GET peers", "GET links", "POST links/changed",
        "GET sync/state", "GET sync/file", "POST sync/changed", "POST optmem/run",
        "POST cli", "GET channels/files", "PUT channels/files",
        "GET attention", "POST attention/presence", "POST attention/*/resolve",
        "GET vault/replica", "POST vault/replica", "POST vault/card-token",
        "GET vault/audit/hashes", "GET vault/audit/mirror", "POST vault/audit/mirror",
        "GET scrub/status", "GET scrub/index", "POST scrub/run", "PUT scrub/schedule",
        "POST tasks", "GET cards/search", "GET cards/*", "PATCH cards/*", "DELETE cards/*",
        "GET cards/*/transcript", "GET cards/*/transcript/raw", "GET cards/*/handover",
        "POST cards/*/prompt", "POST cards/*/interrupt", "POST cards/*/resume", "POST cards/*/move",
        "POST cards/*/worktree/remove", "POST cards/*/discover",
        "POST cards/*/queue/*", "PATCH cards/*/queue/*", "DELETE cards/*/queue/*",
        "POST cards/*/side-chat", "GET cards/*/side-chat/*", "DELETE cards/*/side-chat/*",
        "GET cards/*/slash-commands", "POST cards/*/pasted-image",
    ]

    /// What `kanban remote attach` calls to show a terminal.
    static let terminal: Set<String> = ["GET me", "GET board", "GET cards/*", "GET cards/*/terminal"]

    /// Why a device of `scope` may not call the route, or nil when it may.
    static func refusal(scope: RemoteScope, method: String, rest: [String]) -> String? {
        let allowed: Set<String>
        switch scope {
        case .full, .agent: return nil
        case .peer: allowed = peer
        case .terminal: allowed = terminal
        }
        let route = shape(rest)
        if allowed.contains("\(method) \(route)") { return nil }
        if scope == .peer, route == "cards/*/terminal" { return "the peer scope cannot open terminals" }
        return "the \(scope.rawValue) scope cannot call \(method) /v1/\(rest.joined(separator: "/"))"
    }
}
