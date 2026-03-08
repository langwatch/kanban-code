import Testing
import Foundation
@testable import KanbanCodeCore

// MARK: - Mock Adapters

private final class MockDiscovery: SessionDiscovery, @unchecked Sendable {
    let sessions: [Session]
    init(sessions: [Session] = []) { self.sessions = sessions }
    func discoverSessions() async throws -> [Session] { sessions }
    func discoverNewOrModified(since: Date) async throws -> [Session] { sessions }
}

private actor MockDetector: ActivityDetector {
    private var states: [String: ActivityState] = [:]

    func setState(_ state: ActivityState, for sessionId: String) {
        states[sessionId] = state
    }

    func handleHookEvent(_ event: HookEvent) async {}
    func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        var result: [String: ActivityState] = [:]
        for (id, _) in sessionPaths {
            if let state = states[id] {
                result[id] = state
            }
        }
        return result
    }
    func activityState(for sessionId: String) async -> ActivityState {
        states[sessionId] ?? .stale
    }
}

private final class MockStore: SessionStore, @unchecked Sendable {
    func readTranscript(sessionPath: String) async throws -> [ConversationTurn] { [] }
    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String { "forked-id" }
    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {}
    func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] { [] }
    func searchSessionsStreaming(query: String, paths: [String], onResult: @MainActor @Sendable ([SearchResult]) -> Void) async throws {}
}

// MARK: - Registry Tests

@Suite("CodingAssistantRegistry")
struct RegistryTests {

    @Test("Empty registry has no available assistants")
    func emptyRegistry() {
        let registry = CodingAssistantRegistry()
        #expect(registry.available.isEmpty)
    }

    @Test("Register and retrieve Claude adapters")
    func registerClaude() {
        let registry = CodingAssistantRegistry()
        let discovery = MockDiscovery()
        let detector = MockDetector()
        let store = MockStore()

        registry.register(.claude, discovery: discovery, detector: detector, store: store)

        #expect(registry.discovery(for: .claude) != nil)
        #expect(registry.detector(for: .claude) != nil)
        #expect(registry.store(for: .claude) != nil)
        #expect(registry.available == [.claude])
    }

    @Test("Register both assistants")
    func registerBoth() {
        let registry = CodingAssistantRegistry()
        registry.register(.claude, discovery: MockDiscovery(), detector: MockDetector(), store: MockStore())
        registry.register(.gemini, discovery: MockDiscovery(), detector: MockDetector(), store: MockStore())

        #expect(registry.available.count == 2)
        #expect(registry.available.contains(.claude))
        #expect(registry.available.contains(.gemini))
    }

    @Test("Unregistered assistant returns nil")
    func unregisteredReturnsNil() {
        let registry = CodingAssistantRegistry()
        #expect(registry.discovery(for: .gemini) == nil)
        #expect(registry.detector(for: .gemini) == nil)
        #expect(registry.store(for: .gemini) == nil)
    }

    @Test("Available is sorted by rawValue")
    func availableSorted() {
        let registry = CodingAssistantRegistry()
        // Register gemini first, then claude
        registry.register(.gemini, discovery: MockDiscovery(), detector: MockDetector(), store: MockStore())
        registry.register(.claude, discovery: MockDiscovery(), detector: MockDetector(), store: MockStore())

        // Should be sorted: claude < gemini alphabetically
        #expect(registry.available.first == .claude)
        #expect(registry.available.last == .gemini)
    }
}

// MARK: - Composite Session Discovery Tests

@Suite("CompositeSessionDiscovery")
struct CompositeSessionDiscoveryTests {

    @Test("Merges sessions from multiple assistants sorted by modifiedTime")
    func mergesSessions() async throws {
        let olderDate = Date.now.addingTimeInterval(-3600)
        let newerDate = Date.now.addingTimeInterval(-60)

        let claudeSessions = [
            Session(id: "claude-1", modifiedTime: olderDate, assistant: .claude)
        ]
        let geminiSessions = [
            Session(id: "gemini-1", modifiedTime: newerDate, assistant: .gemini)
        ]

        let registry = CodingAssistantRegistry()
        registry.register(.claude, discovery: MockDiscovery(sessions: claudeSessions), detector: MockDetector(), store: MockStore())
        registry.register(.gemini, discovery: MockDiscovery(sessions: geminiSessions), detector: MockDetector(), store: MockStore())

        let composite = CompositeSessionDiscovery(registry: registry)
        let result = try await composite.discoverSessions()

        #expect(result.count == 2)
        // Newer session first
        #expect(result[0].id == "gemini-1")
        #expect(result[1].id == "claude-1")
    }

    @Test("Returns empty when no assistants registered")
    func emptyRegistry() async throws {
        let registry = CodingAssistantRegistry()
        let composite = CompositeSessionDiscovery(registry: registry)
        let result = try await composite.discoverSessions()
        #expect(result.isEmpty)
    }

    @Test("Continues when one assistant fails")
    func continuesOnFailure() async throws {
        let registry = CodingAssistantRegistry()

        let failingDiscovery = FailingDiscovery()
        let goodSessions = [Session(id: "good-1", modifiedTime: .now, assistant: .gemini)]

        registry.register(.claude, discovery: failingDiscovery, detector: MockDetector(), store: MockStore())
        registry.register(.gemini, discovery: MockDiscovery(sessions: goodSessions), detector: MockDetector(), store: MockStore())

        let composite = CompositeSessionDiscovery(registry: registry)
        let result = try await composite.discoverSessions()

        #expect(result.count == 1)
        #expect(result[0].id == "good-1")
    }
}

private final class FailingDiscovery: SessionDiscovery, @unchecked Sendable {
    func discoverSessions() async throws -> [Session] {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test failure"])
    }
    func discoverNewOrModified(since: Date) async throws -> [Session] {
        throw NSError(domain: "test", code: 1)
    }
}

// MARK: - Composite Activity Detector Tests

@Suite("CompositeActivityDetector")
struct CompositeActivityDetectorTests {

    @Test("Routes hook events to all registered detectors")
    func routesHookToRegistered() async {
        let claudeDetector = MockDetector()
        let registry = CodingAssistantRegistry()
        registry.register(.claude, discovery: MockDiscovery(), detector: claudeDetector, store: MockStore())

        let composite = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await composite.handleHookEvent(event)

        // The registered detector should have received the event
        // (MockDetector ignores it, but we verify the call doesn't crash)
    }

    @Test("activityState returns highest-priority result across detectors")
    func activityStateHighestPriority() async {
        let claudeDetector = MockDetector()
        let geminiDetector = MockDetector()
        await geminiDetector.setState(.activelyWorking, for: "s1")

        let registry = CodingAssistantRegistry()
        registry.register(.claude, discovery: MockDiscovery(), detector: claudeDetector, store: MockStore())
        registry.register(.gemini, discovery: MockDiscovery(), detector: geminiDetector, store: MockStore())

        let composite = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)
        let state = await composite.activityState(for: "s1")

        #expect(state == .activelyWorking)
    }

    @Test("activityState returns stale when no detector knows the session")
    func activityStateUnknownSession() async {
        let registry = CodingAssistantRegistry()
        // Only register gemini (which doesn't know about s1)
        registry.register(.gemini, discovery: MockDiscovery(), detector: MockDetector(), store: MockStore())

        let composite = CompositeActivityDetector(registry: registry, defaultDetector: MockDetector())
        let state = await composite.activityState(for: "s1")

        #expect(state == .stale)
    }

    @Test("pollActivity merges results from all detectors")
    func pollActivityMerges() async {
        let claudeDetector = MockDetector()
        await claudeDetector.setState(.activelyWorking, for: "c1")

        let geminiDetector = MockDetector()
        await geminiDetector.setState(.needsAttention, for: "g1")

        let registry = CodingAssistantRegistry()
        registry.register(.claude, discovery: MockDiscovery(), detector: claudeDetector, store: MockStore())
        registry.register(.gemini, discovery: MockDiscovery(), detector: geminiDetector, store: MockStore())

        let composite = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)
        let result = await composite.pollActivity(sessionPaths: [
            "c1": "/path/to/claude/session",
            "g1": "/path/to/gemini/session",
        ])

        #expect(result["c1"] == .activelyWorking)
        #expect(result["g1"] == .needsAttention)
    }
}
