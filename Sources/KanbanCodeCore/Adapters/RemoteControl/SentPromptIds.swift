import Foundation

/// The sender ids of prompts this master took lately, per card, so a
/// prompt sent again with the same id (a retry after the answer was lost)
/// is not sent twice. A claim is held while the send runs, so two copies
/// arriving at once send one.
public final class SentPromptIds: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var keys: Set<String> = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    /// Claims the id for the card; false when it was claimed already.
    public func claim(cardId: String, id: String) -> Bool {
        let key = cardId + "\n" + id
        return lock.withLock {
            guard !keys.contains(key) else { return false }
            keys.insert(key)
            order.append(key)
            if order.count > capacity {
                keys.remove(order.removeFirst())
            }
            return true
        }
    }

    /// Gives the id back after a send that did not happen, so a retry goes.
    public func release(cardId: String, id: String) {
        let key = cardId + "\n" + id
        lock.withLock {
            keys.remove(key)
            order.removeAll { $0 == key }
        }
    }
}
