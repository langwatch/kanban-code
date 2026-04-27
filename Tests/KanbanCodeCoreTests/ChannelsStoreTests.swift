import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ChannelsStore")
struct ChannelsStoreTests {
    private func tmpBase() -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-channels-\(UUID().uuidString)")
            .path
        return base
    }

    @Test func createAndLoadChannel() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        let by = ChannelParticipant(cardId: nil, handle: "user")

        let ch = try await store.createChannel(name: "general", by: by)
        #expect(ch.name == "general")

        let loaded = await store.loadChannels()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "general")
    }

    @Test func joinAppendsEvent() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        _ = try await store.createChannel(name: "general", by: ChannelParticipant(cardId: nil, handle: "user"))
        let (_, already) = try await store.join(
            channel: "general",
            member: ChannelParticipant(cardId: "card_A", handle: "alice")
        )
        #expect(already == false)

        let msgs = await store.loadMessages(channel: "general")
        #expect(msgs.count == 1)
        #expect(msgs[0].type == .join)
        #expect(msgs[0].body.contains("@alice joined"))
    }

    @Test func sendAppendsMessageLine() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        _ = try await store.createChannel(name: "general", by: ChannelParticipant(cardId: nil, handle: "user"))
        _ = try await store.send(
            channel: "general",
            from: ChannelParticipant(cardId: nil, handle: "user"),
            body: "hello"
        )
        let msgs = await store.loadMessages(channel: "general")
        #expect(msgs.count == 1)
        #expect(msgs[0].body == "hello")
        #expect(msgs[0].type == .message)
    }

    @Test func loadMessagesWithLimitReturnsTail() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        _ = try await store.createChannel(name: "general", by: ChannelParticipant(cardId: nil, handle: "user"))
        for idx in 0..<5 {
            _ = try await store.send(
                channel: "general",
                from: ChannelParticipant(cardId: nil, handle: "user"),
                body: "message \(idx)"
            )
        }

        let msgs = await store.loadMessages(channel: "general", limit: 2)
        #expect(msgs.map(\.body) == ["message 3", "message 4"])
    }

    @Test func jsonlOnDiskInteroperatesWithCLIFormat() async throws {
        // Write a file using the same format the TS CLI writes, then read it
        // back through the Swift store and verify we parse it correctly.
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let channelsDir = (base as NSString).appendingPathComponent("channels")
        try FileManager.default.createDirectory(atPath: channelsDir, withIntermediateDirectories: true)

        let channelsFile = (channelsDir as NSString).appendingPathComponent("channels.json")
        let cliJson = """
        {
          "channels": [
            {
              "id": "ch_abc",
              "name": "general",
              "createdAt": "2026-04-18T15:00:00.000Z",
              "createdBy": {"cardId": null, "handle": "user"},
              "members": [
                {"cardId": "card_A", "handle": "alice", "joinedAt": "2026-04-18T15:05:00.000Z"}
              ]
            }
          ]
        }
        """
        try cliJson.write(toFile: channelsFile, atomically: true, encoding: .utf8)

        let logFile = (channelsDir as NSString).appendingPathComponent("general.jsonl")
        let cliJsonl = """
        {"id":"msg_1","ts":"2026-04-18T15:10:00.000Z","from":{"cardId":"card_A","handle":"alice"},"body":"hi","type":"message"}
        {"id":"msg_2","ts":"2026-04-18T15:11:00.000Z","from":{"cardId":null,"handle":"user"},"body":"hi back"}
        """
        try cliJsonl.write(toFile: logFile, atomically: true, encoding: .utf8)

        let store = ChannelsStore(baseDir: base)
        let chs = await store.loadChannels()
        #expect(chs.count == 1)
        #expect(chs[0].name == "general")
        #expect(chs[0].members.first?.handle == "alice")

        let msgs = await store.loadMessages(channel: "general")
        #expect(msgs.count == 2)
        #expect(msgs[0].body == "hi")
        #expect(msgs[1].body == "hi back")
        // Second message has no type field — should default to .message
        #expect(msgs[1].type == .message)
    }

    @Test func leaveRemovesMemberAndAppendsLeaveEvent() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        _ = try await store.createChannel(
            name: "general",
            by: ChannelParticipant(cardId: nil, handle: "user")
        )
        _ = try await store.join(
            channel: "general",
            member: ChannelParticipant(cardId: "card_A", handle: "alice")
        )

        let ch = try await store.leave(
            channel: "general",
            member: ChannelParticipant(cardId: "card_A", handle: "alice")
        )
        #expect(ch?.members.isEmpty == true)

        let reloaded = await store.loadChannels()
        #expect(reloaded[0].members.isEmpty, "channels.json must reflect the removal on disk")

        let msgs = await store.loadMessages(channel: "general")
        // join + leave events
        #expect(msgs.count == 2)
        #expect(msgs.last?.type == .leave)
        #expect(msgs.last?.body == "@alice left #general")
    }

    @Test func leaveMatchesByHandleWhenCardIdIsMissing() async throws {
        // Covers kicking a member whose card has already been deleted — the
        // entry on disk still has a cardId, but we pass only the handle.
        // Matching by handle lets the kick action work for ghost agents.
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        _ = try await store.createChannel(
            name: "general", by: ChannelParticipant(cardId: nil, handle: "user")
        )
        _ = try await store.join(
            channel: "general",
            member: ChannelParticipant(cardId: "card_dead", handle: "ghost")
        )

        let ch = try await store.leave(
            channel: "general",
            member: ChannelParticipant(cardId: nil, handle: "ghost")
        )
        #expect(ch?.members.isEmpty == true)
    }

    @Test func leaveIsNoOpForUnknownChannel() async throws {
        let base = tmpBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = ChannelsStore(baseDir: base)
        let ch = try await store.leave(
            channel: "does-not-exist",
            member: ChannelParticipant(cardId: nil, handle: "alice")
        )
        #expect(ch == nil)
    }
}
