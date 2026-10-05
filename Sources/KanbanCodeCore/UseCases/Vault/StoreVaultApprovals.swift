import Foundation

/// Vault approvals as attention requests on the board store: the Mac and
/// the phone show them, and whoever answers first resolves them.
public struct StoreVaultApprovals: VaultApprovals {
    private let store: BoardStore

    public init(store: BoardStore) {
        self.store = store
    }

    public func raise(_ request: AttentionRequest) async {
        await MainActor.run { store.dispatch(.attentionRaised(request)) }
    }

    public func resolution(of id: String) async -> (resolution: String?, by: String)? {
        await MainActor.run {
            guard let request = store.state.attentionRequests[id], !request.isOpen else { return nil }
            return (request.resolution, request.resolvedBy ?? "unknown")
        }
    }

    public func close(id: String, resolution: String, by: String) async {
        await MainActor.run { store.dispatch(.attentionResolved(id: id, resolution: resolution, by: by)) }
    }
}

extension BoardStore {
    /// Terminal session name -> card id, for every card on this master.
    @MainActor public func vaultCardSessions() -> [String: String] {
        var out: [String: String] = [:]
        for (id, link) in state.links {
            for name in link.tmuxLink?.allSessionNames ?? [] { out[name] = id }
        }
        return out
    }

    @MainActor public func vaultCardTitle(_ cardId: String) -> String? {
        state.links[cardId]?.displayTitle
    }

    @MainActor public func vaultCardLink(_ cardId: String) -> Link? {
        state.links[cardId]
    }

    /// The other cards of `cardId`'s subagent tree: its root card and every
    /// card under that root.
    @MainActor public func vaultCardFamily(_ cardId: String) -> [String] {
        let links = state.links
        guard links[cardId] != nil else { return [] }
        let root = SubagentHierarchy.rootId(of: cardId, in: links)
        return ([root] + SubagentHierarchy.descendantIds(of: root, in: links)).filter { $0 != cardId }
    }
}
