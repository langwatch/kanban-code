import Testing
@testable import KanbanCodeCore

@Suite("Subagent hierarchy")
struct SubagentHierarchyTests {
    @Test("Hierarchy helpers support recursive descendants")
    func recursiveHierarchy() {
        let root = Link(id: "root", name: "Root")
        let child = Link(id: "child", name: "Child", parentCardId: root.id)
        let grandchild = Link(id: "grandchild", name: "Grandchild", parentCardId: child.id)
        let links = [root.id: root, child.id: child, grandchild.id: grandchild]

        #expect(SubagentHierarchy.depth(of: root.id, in: links) == 0)
        #expect(SubagentHierarchy.depth(of: child.id, in: links) == 1)
        #expect(SubagentHierarchy.depth(of: grandchild.id, in: links) == 2)
        #expect(SubagentHierarchy.rootId(of: grandchild.id, in: links) == root.id)
        #expect(SubagentHierarchy.descendantIds(of: root.id, in: links) == [child.id, grandchild.id])
        #expect(SubagentHierarchy.descendantCounts(in: links) == [root.id: 2, child.id: 1])
    }

    @Test("Archived children are hidden inline but available to management")
    func archivedChildren() {
        let root = Link(id: "root")
        let active = Link(id: "active", parentCardId: root.id)
        let archived = Link(id: "archived", manuallyArchived: true, parentCardId: root.id)
        let links = [root.id: root, active.id: active, archived.id: archived]

        #expect(SubagentHierarchy.children(of: root.id, in: links).map(\.id) == [active.id])
        #expect(Set(SubagentHierarchy.children(of: root.id, in: links, includeArchived: true).map(\.id)) == [active.id, archived.id])
    }

    @Test("Maximum depth is configurable and defaults to one")
    func maximumDepth() {
        let root = Link(id: "root")
        let child = Link(id: "child", parentCardId: root.id)
        let links = [root.id: root, child.id: child]

        #expect(SubagentHierarchy.canSpawn(from: root.id, in: links, maximumDepth: 1))
        #expect(!SubagentHierarchy.canSpawn(from: child.id, in: links, maximumDepth: 1))
        #expect(!SubagentHierarchy.canSpawn(from: root.id, in: links, maximumDepth: 0))
        #expect(SubagentHierarchy.canSpawn(from: child.id, in: links, maximumDepth: 2))
    }

    @Test("Visible rows flatten recursive children and honor collapsed parents")
    func visibleRows() {
        let root = Link(id: "root")
        let child = Link(id: "child", parentCardId: root.id)
        let sibling = Link(id: "sibling", parentCardId: root.id)
        let grandchild = Link(id: "grandchild", parentCardId: child.id)
        let archived = Link(id: "archived", manuallyArchived: true, parentCardId: child.id)
        let links = Dictionary(uniqueKeysWithValues: [root, child, sibling, grandchild, archived].map { ($0.id, $0) })

        let visible = SubagentHierarchy.visibleDescendants(of: root.id, in: links)
        #expect(Set(visible.map(\.cardId)) == [child.id, sibling.id, grandchild.id])
        #expect(visible.first(where: { $0.cardId == child.id })?.depth == 1)
        #expect(visible.first(where: { $0.cardId == child.id })?.directChildCount == 1)
        #expect(visible.first(where: { $0.cardId == grandchild.id })?.depth == 2)

        let collapsed = SubagentHierarchy.visibleDescendants(
            of: root.id,
            in: links,
            collapsedParentIds: [child.id]
        )
        #expect(!collapsed.contains(where: { $0.cardId == grandchild.id }))

        let managed = SubagentHierarchy.visibleDescendants(
            of: root.id,
            in: links,
            includeArchived: true
        )
        #expect(managed.contains(where: { $0.cardId == archived.id }))
    }
}
