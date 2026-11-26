import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Laze agent directory")
struct LazeAgentDirectoryTests {
    static let config = Data(#"""
    {
      "current": "default",
      "profiles": {
        "default": {"kind": "person", "name": "Rogerio", "token": "person-key", "url": "https://laze.so"},
        "agent-video": {"kind": "agent", "name": "Video Maker", "agentId": "agent_video", "token": "video-key",
                        "url": "https://laze.so", "workspaceId": "workspace_1"},
        "agent-old": {"kind": "agent", "name": "Old", "agentId": "agent_old", "token": "old-key",
                      "url": "https://laze.so", "workspaceId": "workspace_1",
                      "refused": {"code": "unauthorized", "message": "This API key is not valid"}},
        "agent-ops": {"kind": "agent", "name": "Ops", "agentId": "agent_ops", "token": "ops-key",
                      "url": "https://laze.so/", "workspaceId": "workspace_1"}
      },
      "sessions": {
        "claude-code:s-video-old": "agent-video",
        "claude-code:s-old": "agent-old",
        "codex:s-ops": "agent-ops"
      }
    }
    """#.utf8)

    @Test("the config gives the agent profiles with a working key and the session bindings")
    func parseConfig() {
        let config = LazeAgentDirectory.parseConfig(Self.config)
        #expect(config.profiles.map(\.name) == ["agent-ops", "agent-video"])
        #expect(config.profiles.first { $0.name == "agent-video" }?.agentId == "agent_video")
        #expect(config.sessions["s-video-old"] == "agent-video")
        #expect(config.sessions["s-ops"] == "agent-ops")
        #expect(LazeAgentDirectory.parseConfig(Data("not json".utf8)).profiles.isEmpty)
    }

    @Test("Laze's binding wins over the config's; the config stands in when Laze did not answer")
    func resolve() {
        let config = LazeAgentDirectory.parseConfig(Self.config)
        let me = ["agent-video": LazeAgentDirectory.Me(id: "agent_video", name: "Rogerio Video Maker", avatar: "", sessionId: "s-video")]
        let faces = ["agent_video": LazeAgentDirectory.Face(name: "Rogerio Video Maker", seed: "agent_video", imageUrl: nil, emoji: nil)]
        let agents = LazeAgentDirectory.resolve(config: config, me: me, faces: faces)
        #expect(agents["s-video"] == RemoteLazeAgent(id: "agent_video", name: "Rogerio Video Maker"))
        #expect(agents["s-video-old"] == nil)
        // Ops did not answer: its config binding and profile name stand in.
        #expect(agents["s-ops"] == RemoteLazeAgent(id: "agent_ops", name: "Ops"))
        #expect(agents["s-old"] == nil)
    }

    @Test("a stored avatar decides the face when the faces list is missing")
    func look() {
        #expect(LazeAgentDirectory.look(avatar: "sloth:ab12", agentId: "agent_1") == ("ab12", nil))
        #expect(LazeAgentDirectory.look(avatar: "animals:cd34", agentId: "agent_1") == ("cd34", nil))
        #expect(LazeAgentDirectory.look(avatar: "emoji:🦊", agentId: "agent_1") == ("agent_1", "🦊"))
        #expect(LazeAgentDirectory.look(avatar: "file:f_1", agentId: "agent_1") == ("agent_1", nil))
        #expect(LazeAgentDirectory.look(avatar: "", agentId: "agent_1") == ("agent_1", nil))
    }

    @Test("load asks Laze with each agent's key and reads me and faces")
    func load() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("laze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path
        try Self.config.write(to: URL(fileURLWithPath: path))
        let asked = LockedList()
        let agents = await LazeAgentDirectory.load(path: path) { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            asked.append("\(auth) \(request.url?.absoluteString ?? "")")
            switch (request.url?.path, auth) {
            case ("/api/agents/me", "Bearer video-key"):
                return Data(#"{"kind":"agent","id":"agent_video","name":"Rogerio Video Maker","agent":{"avatar":"emoji:🎬","session":{"harness":"claude-code","sessionId":"s-video"}}}"#.utf8)
            case ("/api/agents/me", "Bearer ops-key"):
                return Data(#"{"kind":"agent","id":"agent_ops","name":"Ops Desk","agent":{"avatar":"","session":null}}"#.utf8)
            case ("/api/agents/faces", _):
                return Data(#"[{"agentId":"agent_video","name":"Rogerio Video Maker","roster":"sloth","seed":"agent_video","imageUrl":"https://files.laze.so/a.png","gone":false},{"agentId":"agent_gone","name":"Gone","seed":"x","imageUrl":null,"gone":true}]"#.utf8)
            default:
                return nil
            }
        }
        #expect(agents?["s-video"] == RemoteLazeAgent(
            id: "agent_video", name: "Rogerio Video Maker", faceSeed: "agent_video", imageUrl: "https://files.laze.so/a.png"))
        // Ops answered with no session: its old config binding is dropped.
        #expect(agents?["s-ops"] == nil)
        #expect(!asked.items.contains { $0.contains("old-key") })
        #expect(asked.items.contains("Bearer ops-key https://laze.so/api/agents/me"))
        #expect(asked.items.filter { $0.hasSuffix("/api/agents/faces") }.count == 1)
        #expect(await LazeAgentDirectory.load(path: dir.appendingPathComponent("none.json").path) { _ in nil } == nil)
    }

    @Test("a card shows the Laze agent of its session, and a peer's card the one its owner reports")
    func cardsCarryTheAgent() {
        let state = AppState()
        let agent = RemoteLazeAgent(id: "agent_video", name: "Video Maker")
        state.links = ["card_1": Link(id: "card_1", column: .waiting, source: .manual, sessionLink: SessionLink(sessionId: "s-video"))]
        state.lazeAgents = ["s-video": agent]
        state.rebuildCards()
        let card = state.cards.first { $0.id == "card_1" }
        #expect(card?.lazeAgent == agent)
        #expect(card.map { RemoteBoardMapper.card($0, liveSessions: []).lazeAgent } == agent)
        #expect(PeerTranscriptMirror.state(of: RemoteCard(id: "card_2", title: "x", column: .waiting, updatedAt: Date(), lazeAgent: agent)).lazeAgent == agent)
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ item: String) { lock.withLock { list.append(item) } }
    var items: [String] { lock.withLock { list } }
}
