import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ActivityDetector")
struct ActivityDetectorTests {

    // MARK: - Hook-based detection

    @Test("UserPromptSubmit → activelyWorking")
    func userPromptSubmit() async {
        let detector = ClaudeCodeActivityDetector()
        let event = HookEvent(sessionId: "s1", eventName: "UserPromptSubmit")
        await detector.handleHookEvent(event)
        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("Stop → needsAttention after grace period")
    func stopImmediate() async {
        // Zero grace period so this test is deterministic
        let detector = ClaudeCodeActivityDetector(stopDelay: 0)
        let event = HookEvent(sessionId: "s1", eventName: "Stop")
        await detector.handleHookEvent(event)

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    @Test("Stop within grace period → activelyWorking (flicker suppression)")
    func stopGracePeriod() async {
        // 5-second grace
        let detector = ClaudeCodeActivityDetector(stopDelay: 5)
        let event = HookEvent(sessionId: "s1", eventName: "Stop", timestamp: Date.now)
        await detector.handleHookEvent(event)

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "Within stopDelay, Stop should not yet demote — prevents flicker when a new UserPromptSubmit is imminent")
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

    @Test("Notification without file path → needsAttention")
    func notification() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Notification"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention)
    }

    // MARK: - Stop/Notification + file mtime (resumed work detection)

    @Test("Old Stop event + file not written after Stop → needsAttention (truly stopped)")
    func stopEventuallyDemotes() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 1)
        let stopTime = Date.now.addingTimeInterval(-10)
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1",
            eventName: "Stop",
            timestamp: stopTime
        ))

        // Transcript mtime == Stop time (Claude's last flush, nothing after).
        // Outside grace + no further writes → Claude is truly done.
        let dir = NSTemporaryDirectory() + "kanban-code-stop-old-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: stopTime], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "Stop outside grace + no post-Stop writes means Claude is done")
    }

    @Test("Old Stop event + file written after Stop → activelyWorking (ralph-loop continuation)")
    func stopWithPostStopWrites() async {
        // Ralph-loop and similar stop-hook continuation frameworks inject
        // additional context, so Claude continues writing without firing a
        // new UserPromptSubmit. The transcript mtime advancing past the
        // Stop timestamp is the only signal we have.
        let detector = ClaudeCodeActivityDetector(stopDelay: 1)
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1",
            eventName: "Stop",
            timestamp: Date.now.addingTimeInterval(-30)
        ))

        let dir = NSTemporaryDirectory() + "kanban-code-stop-continuation-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        // Write() sets mtime to now — 30s after the Stop event.
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "Post-Stop transcript writes indicate continuation in progress")
    }

    @Test("Stop + stale file → needsAttention")
    func stopWithStaleFile() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0)
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        let dir = NSTemporaryDirectory() + "kanban-code-stop-stale-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let staleDate = Date.now.addingTimeInterval(-10)
        try? FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "Stop + stale file means Claude is done")
    }

    @Test("Notification + fresh file → activelyWorking (Claude working during notification)")
    func notificationWithFreshFile() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Notification"))

        let dir = NSTemporaryDirectory() + "kanban-code-notif-fresh-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "Notification + fresh file means Claude is still working")
    }

    @Test("Notification + stale file → needsAttention")
    func notificationWithStaleFile() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Notification"))

        let dir = NSTemporaryDirectory() + "kanban-code-notif-stale-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let staleDate = Date.now.addingTimeInterval(-10)
        try? FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "Notification + stale file means Claude needs attention")
    }

    @Test("Stop grace window then new UserPromptSubmit → activelyWorking (ralph loop flow)")
    func stopResumedByNewPrompt() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 5)
        // Stop happened "just now" (inside grace window)
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        var state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)

        // New UserPromptSubmit lands — must flip to activelyWorking regardless of grace
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        let dir = NSTemporaryDirectory() + "kanban-code-resume-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])
        state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
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

    // MARK: - 5-minute timeout (replaces old 3s Ctrl+C detection)

    @Test("UserPromptSubmit stays activelyWorking when file is fresh")
    func activeWithFreshFile() async {
        let detector = ClaudeCodeActivityDetector()

        // Simulate: UserPromptSubmit 10 seconds ago, but file is still being written to
        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-10)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-code-fresh-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        // File was just modified (now) — Claude is still writing
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking)
    }

    @Test("UserPromptSubmit stays activelyWorking during sleep 60s (file 60s old)")
    func activeDuringSleep() async {
        let detector = ClaudeCodeActivityDetector()

        // UserPromptSubmit 65 seconds ago
        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-65)
        )
        await detector.handleHookEvent(event)

        // File modified 60 seconds ago — simulates `sleep 60s` tool call
        let dir = NSTemporaryDirectory() + "kanban-code-sleep-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let sleepDate = Date.now.addingTimeInterval(-60)
        try? FileManager.default.setAttributes([.modificationDate: sleepDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        // Should still be activelyWorking — 60s < 5min timeout
        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "File 60s old should not trigger timeout (< 5min)")
    }

    // MARK: - Ctrl+C detection via "[Request interrupted by user]"

    @Test("Ctrl+C detected: file stale >3s + last line is interrupted → needsAttention")
    func ctrlCDetected() async {
        let detector = ClaudeCodeActivityDetector()

        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-10)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-code-ctrlc-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")

        // Write a jsonl with the tool-use interrupt marker as last line
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":"Working on it..."}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        ]
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        // Set file mtime to 5 seconds ago (past 3s grace)
        let staleDate = Date.now.addingTimeInterval(-5)
        try? FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "Ctrl+C should be detected from last jsonl line")
    }

    @Test("Ctrl+C NOT detected when file is still fresh (<3s)")
    func ctrlCNotDetectedWhenFresh() async {
        let detector = ClaudeCodeActivityDetector()

        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-1)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-code-ctrlc-fresh-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")

        // Interrupt marker present, but file is fresh (just written)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        ]
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "Within 3s grace period, ignore interrupt marker")
    }

    @Test("Stale file without interrupt marker stays activelyWorking")
    func staleFileNoInterrupt() async {
        let detector = ClaudeCodeActivityDetector()

        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-10)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-code-stale-noint-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")

        // File is 10s old but last line is a normal assistant message (e.g. sleep 60s)
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":"Running tests..."}}"#,
        ]
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let staleDate = Date.now.addingTimeInterval(-10)
        try? FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .activelyWorking, "Stale file without interrupt should stay active (could be sleep 60s)")
    }

    // MARK: - 5-minute timeout (safety net for killed process)

    @Test("UserPromptSubmit transitions to needsAttention after 5-minute file timeout")
    func timeoutAfterFiveMinutes() async {
        // Use a short timeout for testing (10 seconds instead of 300)
        let detector = ClaudeCodeActivityDetector(activeTimeout: 10)

        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-30)
        )
        await detector.handleHookEvent(event)

        // File modified 15 seconds ago — exceeds the 10s test timeout
        let dir = NSTemporaryDirectory() + "kanban-code-timeout-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-15)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "File older than timeout should trigger needsAttention")
    }

    @Test("UserPromptSubmit with no file path falls back after timeout")
    func noFilePathFallback() async {
        let detector = ClaudeCodeActivityDetector(activeTimeout: 10)

        // Hook from 30s ago, no pollActivity called (no file path cached)
        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-30)
        )
        await detector.handleHookEvent(event)

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "No file path + stale hook should fall back to needsAttention")
    }

    // MARK: - Polling never returns .activelyWorking

    @Test("Poll activity: recently modified file → idleWaiting (NOT activelyWorking)")
    func pollRecentIsIdle() async {
        let dir = NSTemporaryDirectory() + "kanban-code-poll-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .idleWaiting, "Polling should never return .activelyWorking")
    }

    @Test("Poll activity: file 10 minutes old → needsAttention")
    func pollOldFile() async {
        let dir = NSTemporaryDirectory() + "kanban-code-poll-old-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-600) // 10 minutes
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .needsAttention)
    }

    @Test("Poll activity: file 2 hours old → ended")
    func pollEndedFile() async {
        let dir = NSTemporaryDirectory() + "kanban-code-poll-ended-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-7200) // 2 hours
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .ended)
    }

    @Test("Poll activity: file 2 days old → stale")
    func pollStaleFile() async {
        let dir = NSTemporaryDirectory() + "kanban-code-poll-stale-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        let oldDate = Date.now.addingTimeInterval(-172800) // 2 days
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)

        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": path])
        #expect(states["s1"] == .stale)
    }

    @Test("Poll activity: missing file → ended")
    func pollMissingFile() async {
        let detector = ClaudeCodeActivityDetector()
        let states = await detector.pollActivity(sessionPaths: ["s1": "/nonexistent/path.jsonl"])
        #expect(states["s1"] == .ended)
    }

    // MARK: - Hook + poll interaction

    @Test("Session without hooks uses polled state (never activelyWorking)")
    func noHooksUsesPolled() async {
        let dir = NSTemporaryDirectory() + "kanban-code-nohook-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        // File just modified — externally started session
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)

        let detector = ClaudeCodeActivityDetector()
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        // No hook events, so activityState uses polled state
        let state = await detector.activityState(for: "s1")
        #expect(state == .idleWaiting, "Sessions without hooks should never be activelyWorking")
    }

    @Test("Unknown hook event uses polled state, never activelyWorking")
    func unknownHookEvent() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SomeUnknownEvent"))

        let state = await detector.activityState(for: "s1")
        #expect(state == .idleWaiting, "Unknown hook events should fall back to idleWaiting")
    }

    // MARK: - Configurable timeout

    @Test("Custom activeTimeout is respected")
    func customTimeout() async {
        // 5-second timeout for fast test
        let detector = ClaudeCodeActivityDetector(activeTimeout: 5)

        let event = HookEvent(
            sessionId: "s1",
            eventName: "UserPromptSubmit",
            timestamp: Date.now.addingTimeInterval(-10)
        )
        await detector.handleHookEvent(event)

        let dir = NSTemporaryDirectory() + "kanban-code-custom-timeout-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("test.jsonl")
        try? "data".write(toFile: path, atomically: true, encoding: .utf8)
        // File 8s old — exceeds 5s timeout
        let oldDate = Date.now.addingTimeInterval(-8)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        let _ = await detector.pollActivity(sessionPaths: ["s1": path])

        let state = await detector.activityState(for: "s1")
        #expect(state == .needsAttention, "Should timeout with custom activeTimeout")
    }
}
