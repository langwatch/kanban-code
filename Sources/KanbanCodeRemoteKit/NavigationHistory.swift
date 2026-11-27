import Foundation

/// Back and forward through the screens opened one after another, like a
/// browser: opening a new one records the one left and clears forward;
/// back and forward skip the ones no longer there. The Mac's card history
/// (Cmd+[ and Cmd+]) works the same way.
public struct NavigationHistory<Target: Equatable & Sendable>: Sendable {
    public private(set) var backStack: [Target] = []
    public private(set) var forwardStack: [Target] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    /// The user went from `old` to `new` themselves.
    public mutating func record(from old: Target?, to new: Target?) {
        guard old != new else { return }
        if let old {
            backStack.append(old)
            if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        }
        forwardStack.removeAll()
    }

    public func canGoBack(from current: Target?, isAvailable: (Target) -> Bool = { _ in true }) -> Bool {
        backStack.contains { $0 != current && isAvailable($0) }
    }

    public func canGoForward(from current: Target?, isAvailable: (Target) -> Bool = { _ in true }) -> Bool {
        forwardStack.contains { $0 != current && isAvailable($0) }
    }

    /// The screen to go back to, or nil; `current` goes on the forward stack.
    public mutating func back(from current: Target?, isAvailable: (Target) -> Bool = { _ in true }) -> Target? {
        while let target = backStack.popLast() {
            guard target != current, isAvailable(target) else { continue }
            if let current { forwardStack.append(current) }
            return target
        }
        return nil
    }

    /// The screen to go forward to, or nil; `current` goes on the back stack.
    public mutating func forward(from current: Target?, isAvailable: (Target) -> Bool = { _ in true }) -> Target? {
        while let target = forwardStack.popLast() {
            guard target != current, isAvailable(target) else { continue }
            if let current { backStack.append(current) }
            return target
        }
        return nil
    }
}
