import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Link Assistant Codable")
struct LinkAssistantCodableTests {

    // MARK: - Round-trip

    @Test("Link with claude assistant round-trips through JSON")
    func linkClaudeRoundTrip() throws {
        let link = Link(
            id: "card_test1",
            projectPath: "/test/project",
            assistant: .claude
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(link)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Link.self, from: data)
        #expect(decoded.assistant == .claude)
        #expect(decoded.effectiveAssistant == .claude)
    }

    @Test("Link with gemini assistant round-trips through JSON")
    func linkGeminiRoundTrip() throws {
        let link = Link(
            id: "card_test2",
            projectPath: "/test/project",
            assistant: .gemini
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(link)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Link.self, from: data)
        #expect(decoded.assistant == .gemini)
        #expect(decoded.effectiveAssistant == .gemini)
    }

    @Test("Link with codex assistant round-trips through JSON")
    func linkCodexRoundTrip() throws {
        let link = Link(
            id: "card_test3",
            projectPath: "/test/project",
            assistant: .codex
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(link)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Link.self, from: data)
        #expect(decoded.assistant == .codex)
        #expect(decoded.effectiveAssistant == .codex)
    }

    // MARK: - Backward Compatibility

    @Test("Link without assistant field decodes as nil, effectiveAssistant is .claude")
    func backwardCompatNoAssistant() throws {
        // Simulate old JSON without "assistant" key
        let json = """
        {
            "id": "card_old",
            "column": "backlog",
            "manualOverrides": {},
            "manuallyArchived": false,
            "source": "manual",
            "isRemote": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Link.self, from: json.data(using: .utf8)!)
        #expect(decoded.assistant == nil)
        #expect(decoded.effectiveAssistant == .claude)
    }

    @Test("Link with explicit claude assistant encodes the field")
    func explicitClaudeEncodesField() throws {
        let link = Link(id: "card_explicit", assistant: .claude)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(link)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"assistant\""))
        #expect(json.contains("\"claude\""))
    }

    @Test("Link with nil assistant omits the field")
    func nilAssistantOmitsField() throws {
        let link = Link(id: "card_nil")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(link)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"assistant\""))
    }

    // MARK: - Session entity

    @Test("Session defaults to claude assistant")
    func sessionDefaultAssistant() {
        let session = Session(id: "sess-1")
        #expect(session.assistant == .claude)
    }

    @Test("Session with gemini assistant")
    func sessionGeminiAssistant() {
        let session = Session(id: "sess-2", assistant: .gemini)
        #expect(session.assistant == .gemini)
    }

    @Test("Session with codex assistant")
    func sessionCodexAssistant() {
        let session = Session(id: "sess-3", assistant: .codex)
        #expect(session.assistant == .codex)
    }

    // MARK: - effectiveAssistant

    @Test("effectiveAssistant returns .claude when assistant is nil")
    func effectiveAssistantNilClaude() {
        let link = Link(id: "card_eff1")
        #expect(link.assistant == nil)
        #expect(link.effectiveAssistant == .claude)
    }

    @Test("effectiveAssistant returns .gemini when set")
    func effectiveAssistantGemini() {
        let link = Link(id: "card_eff2", assistant: .gemini)
        #expect(link.effectiveAssistant == .gemini)
    }

    @Test("effectiveAssistant returns .codex when set")
    func effectiveAssistantCodex() {
        let link = Link(id: "card_eff3", assistant: .codex)
        #expect(link.effectiveAssistant == .codex)
    }
}
