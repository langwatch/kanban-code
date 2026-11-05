import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Conversations: incremental fold")
struct ConversationIncrementalFoldTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func events() -> [ConversationEvent] {
        var events: [ConversationEvent] = [
            .created("swift-otter", at: t0),
            .created("calm-heron", title: "Leases", at: t0.addingTimeInterval(1)),
        ]
        for i in 0..<40 {
            let conv = i % 3 == 0 ? "calm-heron" : "swift-otter"
            events.append(.message(conv, id: "m\(i)", role: i % 2 == 0 ? .human : .agent,
                                   text: "message \(i)\nwith a second line", at: t0.addingTimeInterval(Double(2 + i))))
        }
        events.append(.message("swift-otter", id: "m1", role: .agent, text: "m1 edited", at: t0.addingTimeInterval(50)))
        events.append(.retracted("swift-otter", id: "m4", at: t0.addingTimeInterval(51)))
        events.append(.title("swift-otter", "Vault", by: "agent", at: t0.addingTimeInterval(52)))
        events.append(.read("calm-heron", at: t0.addingTimeInterval(53)))
        events.append(.message("swift-otter", id: "m99", role: .agent, text: "after the retract", at: t0.addingTimeInterval(54)))
        return events
    }

    private func log(_ events: [ConversationEvent]) -> Data {
        events.reduce(into: Data()) { $0.append($1.line()) }
    }

    @Test("feeding the log in pieces, cut anywhere, folds to what reading it whole does")
    func piecesMatchWhole() {
        let data = log(events())
        let whole = ConversationLog.fold(data)
        #expect(whole.count == 2)
        for cut in [1, 7, 64, 333, data.count / 2, data.count - 1] {
            var folder = ConversationLog.Folder()
            var offset = 0
            while offset < data.count {
                // The reader hands over the bytes from `consumed` on, as a
                // file read would after the last whole line.
                let end = min(offset + cut, data.count)
                folder.feed(data.subdata(in: folder.consumed..<end))
                offset = end
                #expect(folder.threads == ConversationLog.fold(data.subdata(in: 0..<end)))
            }
            #expect(folder.threads == whole)
            #expect(folder.consumed == data.count)
        }
    }

    @Test("a last line without its newline shows, and is read again once whole")
    func unterminatedTail() {
        var data = log(Array(events().prefix(5)))
        var last = ConversationEvent.message("swift-otter", id: "tail", role: .agent, text: "the end").line()
        last.removeLast()
        data.append(last)
        var folder = ConversationLog.Folder()
        folder.feed(data)
        #expect(folder.threads == ConversationLog.fold(data))
        #expect(folder.threads.first { $0.summary.id == "swift-otter" }?.messages.last?.id == "tail")
        #expect(folder.consumed == data.count - last.count)
    }

    @Test("the store reads a log again only from where it stopped, and from the start when it shrank")
    func storeIncremental() throws {
        let dir = NSTemporaryDirectory() + "kanban-conv-fold-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ConversationStore(kanbanHome: dir)
        let all = events()
        try store.append(cardId: "card_a", Array(all.prefix(10)))
        let path = store.path(cardId: "card_a")
        #expect(store.threads(cardId: "card_a") == ConversationLog.fold(path: path))

        try store.append(cardId: "card_a", Array(all.dropFirst(10)))
        #expect(store.threads(cardId: "card_a") == ConversationLog.fold(path: path))
        #expect(store.threads(cardId: "card_a") == ConversationLog.fold(log(all)))

        // A mirror copied again from the start: shorter than what was read.
        try log(Array(all.prefix(3))).write(to: URL(fileURLWithPath: path))
        #expect(store.threads(cardId: "card_a") == ConversationLog.fold(log(Array(all.prefix(3)))))

        try FileManager.default.removeItem(atPath: path)
        #expect(store.threads(cardId: "card_a").isEmpty)
    }

    @Test("folding a log runs on any thread, so readers off the main actor see the same result")
    func foldOffMain() async throws {
        let dir = NSTemporaryDirectory() + "kanban-conv-fold-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ConversationStore(kanbanHome: dir)
        try store.append(cardId: "card_a", events())
        let expected = ConversationLog.fold(log(events()))
        let results = await withTaskGroup(of: [ConversationThread].self) { group in
            for _ in 0..<8 {
                group.addTask { await Task.detached { store.threads(cardId: "card_a") }.value }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == expected })
    }

    @Test("transcript copies made in one pass reach the board in one action")
    func mirroredPathsBatch() {
        let state = AppState()
        _ = Reducer.reduce(state: state, action: .peerTranscriptsMirrored(paths: ["s1": "/peers/a/s1.jsonl", "s2": "/peers/a/s2.jsonl"]))
        #expect(state.peerTranscriptPaths == ["s1": "/peers/a/s1.jsonl", "s2": "/peers/a/s2.jsonl"])
        _ = Reducer.reduce(state: state, action: .peerTranscriptsMirrored(paths: ["s2": "/peers/b/s2.jsonl"]))
        #expect(state.peerTranscriptPaths == ["s1": "/peers/a/s1.jsonl", "s2": "/peers/b/s2.jsonl"])
    }
}
