import Foundation

public struct SubagentHierarchyRow: Identifiable, Equatable, Sendable {
    public let cardId: String
    public let depth: Int
    public let directChildCount: Int

    public var id: String { cardId }

    public init(cardId: String, depth: Int, directChildCount: Int) {
        self.cardId = cardId
        self.depth = depth
        self.directChildCount = directChildCount
    }
}

/// Pure helpers for traversing first-class subagent cards.
public enum SubagentHierarchy {
    public static func children(
        of parentId: String,
        in links: [String: Link],
        includeArchived: Bool = false
    ) -> [Link] {
        links.values
            .filter { $0.parentCardId == parentId && (includeArchived || !$0.manuallyArchived) }
            .sorted(by: displayOrder)
    }

    public static func depth(of cardId: String, in links: [String: Link]) -> Int {
        var depth = 0
        var currentId: String? = cardId
        var visited = Set<String>()
        while let id = currentId,
              visited.insert(id).inserted,
              let parentId = links[id]?.parentCardId {
            depth += 1
            currentId = parentId
        }
        return depth
    }

    public static func rootId(of cardId: String, in links: [String: Link]) -> String {
        var currentId = cardId
        var visited = Set<String>()
        while visited.insert(currentId).inserted,
              let parentId = links[currentId]?.parentCardId,
              links[parentId] != nil {
            currentId = parentId
        }
        return currentId
    }

    public static func descendantIds(of cardId: String, in links: [String: Link]) -> Set<String> {
        let childrenByParent = Dictionary(grouping: links.values.compactMap { link -> Link? in
            link.parentCardId == nil ? nil : link
        }) { $0.parentCardId! }
        var result = Set<String>()
        var visited = Set([cardId])
        var pending = [cardId]
        while let parentId = pending.popLast() {
            for child in childrenByParent[parentId] ?? [] {
                if visited.insert(child.id).inserted {
                    result.insert(child.id)
                    pending.append(child.id)
                }
            }
        }
        return result
    }

    /// Number of descendants for every parent, built in O(cards * hierarchy depth).
    public static func descendantCounts(in links: [String: Link]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for link in links.values {
            var parentId = link.parentCardId
            var visited = Set([link.id])
            while let id = parentId, visited.insert(id).inserted {
                counts[id, default: 0] += 1
                parentId = links[id]?.parentCardId
            }
        }
        return counts
    }

    public static func canSpawn(from cardId: String, in links: [String: Link], maximumDepth: Int) -> Bool {
        maximumDepth > 0 && depth(of: cardId, in: links) < maximumDepth
    }

    public static func visibleDescendants(
        of parentId: String,
        in links: [String: Link],
        collapsedParentIds: Set<String> = [],
        includeArchived: Bool = false
    ) -> [SubagentHierarchyRow] {
        var rows: [SubagentHierarchyRow] = []
        var visited = Set([parentId])
        let childrenByParent = Dictionary(grouping: links.values.filter {
            $0.parentCardId != nil && (includeArchived || !$0.manuallyArchived)
        }) { $0.parentCardId! }
            .mapValues { $0.sorted(by: displayOrder) }

        func appendChildren(of currentParentId: String, depth: Int) {
            for child in childrenByParent[currentParentId] ?? [] {
                guard visited.insert(child.id).inserted else { continue }
                let childCount = childrenByParent[child.id]?.count ?? 0
                rows.append(SubagentHierarchyRow(
                    cardId: child.id,
                    depth: depth,
                    directChildCount: childCount
                ))
                if !collapsedParentIds.contains(child.id) {
                    appendChildren(of: child.id, depth: depth + 1)
                }
            }
        }

        if !collapsedParentIds.contains(parentId) {
            appendChildren(of: parentId, depth: 1)
        }
        return rows
    }

    private static func displayOrder(_ lhs: Link, _ rhs: Link) -> Bool {
        let left = lhs.lastActivity ?? lhs.updatedAt
        let right = rhs.lastActivity ?? rhs.updatedAt
        if left != right { return left > right }
        return lhs.id < rhs.id
    }
}
