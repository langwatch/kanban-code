import Testing
import Foundation
@testable import KanbanCore

@Suite("ActivityDetector")
struct ActivityDetectorTests {

    @Test("UserPromptSubmit → activelyWorking")
    func userPromptSubmit() async {
        let detector = ClaudeCodeActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await detector.handleHookEvent(event)
        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("Stop → immediate needsAttention")
    func stopImmediate() async {
        let detector = ClaudeCodeActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "Stop")
        await detector.handleHookEvent(event)

        // Stop is immediate — no delay
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("Stop + follow-up prompt → activelyWorking")
    func stopThenPrompt() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("SessionEnd → ended")
    func sessionEnd() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionEnd"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .ended)
    }

    @Test("Unknown session → stale")
    func unknownSession() async {
        let detector = ClaudeCodeActivityDetector()
        let state = await detector.activityState(for: "unknown")
        #expect(state == .stale)
    }

    @Test("Notification → needsAttention")
    func notification() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Notification"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("Resolve pending stops returns empty (Stop is immediate)")
    func resolvePendingStops() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "Stop"))

        // Stop no longer creates pending stops — they resolve immediately
        let resolved = await detector.resolvePendingStops()
        #expect(resolved.count == 0)
    }

    @Test("Poll activity detects recent modification as activelyWorking")
    func pollRecent() async {
        let dir = NSTemporaryDirectory() + "kanban-activity-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .activelyWorking)
    }
}
