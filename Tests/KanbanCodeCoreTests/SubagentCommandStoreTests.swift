import Foundation
import Testing
@testable import KanbanCodeCore

struct SubagentCommandStoreTests {
    @Test("Command requests are claimed once and receive an atomic response")
    func claimAndRespond() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-subagent-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let request = SubagentCommandRequest(
            id: "request-1",
            operation: .spawn,
            createdAt: "2026-08-01T10:00:00.000Z",
            parentCardId: "parent-1",
            prompt: "Investigate",
            assistant: .codex,
            model: "gpt-5.4",
            contextThresholdTokens: 250_000
        )
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent("request-1.json"))

        let store = SubagentCommandStore(baseURL: root)
        #expect(try await store.pendingRequestIds() == ["request-1"])
        #expect(try await store.claim(id: "request-1") == request)
        #expect(request.contextThresholdTokens == 250_000)
        #expect(try await store.claim(id: "request-1") == nil)

        let response = SubagentCommandResponse(id: request.id, ok: true, cardId: "child-1")
        try await store.respond(response)
        let data = try Data(contentsOf: root.appendingPathComponent("responses/request-1.json"))
        #expect(try JSONDecoder().decode(SubagentCommandResponse.self, from: data) == response)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("processing/request-1.json").path))
    }

    @Test("Fork requests carry an optional source card and stay backward compatible")
    func forkSourceCardRoundTrip() throws {
        let request = SubagentCommandRequest(
            id: "request-fork",
            operation: .fork,
            createdAt: "2026-08-02T10:00:00.000Z",
            parentCardId: "parent-1",
            sourceCardId: "child-1",
            prompt: "same work, other direction"
        )
        let decoded = try JSONDecoder().decode(
            SubagentCommandRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)
        #expect(decoded.sourceCardId == "child-1")

        let legacy = """
        {
          "id": "request-legacy",
          "operation": "fork",
          "createdAt": "2026-08-02T10:00:00.000Z",
          "parentCardId": "parent-1",
          "prompt": "try another approach"
        }
        """
        let legacyRequest = try JSONDecoder().decode(
            SubagentCommandRequest.self,
            from: Data(legacy.utf8)
        )
        #expect(legacyRequest.sourceCardId == nil)
    }

    @Test("Concurrent command processors treat a lost claim race as already claimed")
    func concurrentClaimIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-subagent-command-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let request = SubagentCommandRequest(
            id: "request-race",
            operation: .spawn,
            createdAt: "2026-08-01T10:00:00.000Z",
            parentCardId: "parent-1",
            prompt: "Investigate"
        )
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent("request-race.json"))

        let firstStore = SubagentCommandStore(baseURL: root)
        let secondStore = SubagentCommandStore(baseURL: root)
        async let first = firstStore.claim(id: request.id)
        async let second = secondStore.claim(id: request.id)
        let results = try await [first, second]

        #expect(results.compactMap { $0 } == [request])
    }

    @Test("A queue request round-trips as a card-level operation")
    func enqueuePromptRoundTrip() throws {
        let request = SubagentCommandRequest(
            id: "request-queue",
            operation: .enqueuePrompt,
            createdAt: "2026-08-01T10:00:00.000Z",
            parentCardId: "card-1",
            cardId: "card-1",
            prompt: "Look at the flaky test when you are free"
        )

        let decoded = try JSONDecoder().decode(
            SubagentCommandRequest.self,
            from: try JSONEncoder().encode(request)
        )

        #expect(decoded == request)
        #expect(decoded.operation == .enqueuePrompt)
    }

    @Test("Interrupted processing requests become explicit failures")
    func recoverInterruptedRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-subagent-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let processing = root.appendingPathComponent("processing")
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        let request = SubagentCommandRequest(
            id: "request-interrupted",
            operation: .fork,
            createdAt: "2026-08-01T10:00:00.000Z",
            parentCardId: "parent-1",
            prompt: "Investigate"
        )
        try JSONEncoder().encode(request).write(
            to: processing.appendingPathComponent("request-interrupted.json")
        )

        let store = SubagentCommandStore(baseURL: root)
        #expect(try await store.recoverInterruptedRequests() == 1)
        let data = try Data(contentsOf: root.appendingPathComponent("responses/request-interrupted.json"))
        let response = try JSONDecoder().decode(SubagentCommandResponse.self, from: data)
        #expect(response.ok == false)
        #expect(response.error?.contains("restarted") == true)
        #expect(!FileManager.default.fileExists(atPath: processing.appendingPathComponent("request-interrupted.json").path))
    }
}
