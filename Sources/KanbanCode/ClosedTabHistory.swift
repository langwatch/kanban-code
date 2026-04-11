import Foundation

/// A closed tab entry remembered for Cmd+Shift+T "reopen".
enum ClosedTab {
    case browser(url: URL)
    case terminal
}

/// In-memory per-card stack of closed tabs. Not persisted across launches.
/// Pops most-recent-first, like Chrome/Safari reopen-closed-tab.
@MainActor
final class ClosedTabHistory {
    static let shared = ClosedTabHistory()

    private var stacks: [String: [ClosedTab]] = [:]
    private let maxPerCard = 20

    private init() {}

    func push(cardId: String, _ entry: ClosedTab) {
        var stack = stacks[cardId] ?? []
        stack.append(entry)
        if stack.count > maxPerCard {
            stack.removeFirst(stack.count - maxPerCard)
        }
        stacks[cardId] = stack
    }

    func pop(cardId: String) -> ClosedTab? {
        guard var stack = stacks[cardId], !stack.isEmpty else { return nil }
        let entry = stack.removeLast()
        stacks[cardId] = stack.isEmpty ? nil : stack
        return entry
    }

    func hasEntries(cardId: String) -> Bool {
        !(stacks[cardId]?.isEmpty ?? true)
    }

    func clearAllForCard(_ cardId: String) {
        stacks[cardId] = nil
    }
}
