import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Laze agent and card origin on the wire")
struct LazeAgentTests {
    @Test("a card leaves out the human origin and carries its Laze agent")
    func encoding() throws {
        let agent = RemoteLazeAgent(id: "agent_1", name: "Video Maker", imageUrl: "https://files.laze.so/a.png")
        var card = RemoteCard(id: "card_1", title: "Render", column: .waiting, updatedAt: Date(timeIntervalSince1970: 0))
        let plain = String(decoding: try JSONEncoder.remote.encode(card), as: UTF8.self)
        #expect(!plain.contains("origin"))
        #expect(!plain.contains("lazeAgent"))

        card.origin = .agent
        card.lazeAgent = agent
        let data = try JSONEncoder.remote.encode(card)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["origin"] as? String == "agent")
        let wire = try #require(json["lazeAgent"] as? [String: Any])
        #expect(wire["name"] as? String == "Video Maker")
        #expect(wire["faceSeed"] as? String == "agent_1")
        let back = try JSONDecoder.remote.decode(RemoteCard.self, from: data)
        #expect(back.origin == .agent)
        #expect(back.lazeAgent == agent)
    }

    @Test("an unknown origin reads as an agent's, a broken agent as none")
    func lenientDecoding() throws {
        let json = #"{"id":"card_1","title":"x","column":"requires_attention","updatedAt":"2026-11-27T10:00:00Z","origin":"lane","lazeAgent":{"name":1}}"#
        let card = try JSONDecoder.remote.decode(RemoteCard.self, from: Data(json.utf8))
        #expect(card.origin == .agent)
        #expect(card.lazeAgent == nil)
        let old = #"{"id":"card_1","title":"x","column":"requires_attention","updatedAt":"2026-11-27T10:00:00Z"}"#
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: Data(old.utf8)).origin == .human)
    }

    @Test("faces come out as Laze draws them")
    func faces() {
        #expect(LazeFaces.seedHash("é😀") == 4_159_213_040)
        let chief = LazeSlothLook(seed: "Chief")
        #expect(chief.fur == .rose)
        #expect(chief.patch == .teardrop)
        #expect(chief.eyes == .sleepy)
        #expect(chief.tilt == -5)
        #expect(chief.blush == false)
        #expect(chief.tuft == true)
        let other = LazeSlothLook(seed: "user_0001ab")
        #expect(other.fur == .sky)
        #expect(other.patch == .round)
        #expect(other.tilt == -6)
        #expect(LazeSlothLook(seed: "channel_x").patch == .stripe)
    }
}
