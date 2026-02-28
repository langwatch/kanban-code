import Foundation

/// Detects Claude Code session activity from hook events and .jsonl file polling.
public actor ClaudeCodeActivityDetector: ActivityDetector {
    /// Stores the last known event per session.
    private var lastEvents: [String: HookEvent] = [:]
    /// Stores the last known mtime per session (for polling fallback).
    private var lastMtimes: [String: Date] = [:]
    /// Sessions that received a Stop but might get a follow-up prompt.
    private var pendingStops: [String: Date] = [:]
    /// Delay before treating a Stop as final (seconds).
    private let stopDelay: TimeInterval

    public init(stopDelay: TimeInterval = 1.0) {
        self.stopDelay = stopDelay
    }

    public func handleHookEvent(_ event: HookEvent) async {
        lastEvents[event.sessionId] = event

        // Clear pending stops on any new activity
        if event.eventName == "UserPromptSubmit" || event.eventName == "SessionStart" {
            pendingStops.removeValue(forKey: event.sessionId)
        }
    }

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        let fileManager = FileManager.default
        var states: [String: ActivityState] = [:]

        for (sessionId, path) in sessionPaths {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                states[sessionId] = .ended
                continue
            }

            let previousMtime = lastMtimes[sessionId]
            lastMtimes[sessionId] = mtime

            let timeSinceModified = Date.now.timeIntervalSince(mtime)

            if timeSinceModified < 10 {
                // Modified in the last 10 seconds — actively working
                states[sessionId] = .activelyWorking
            } else if timeSinceModified < 60 {
                // Modified in the last minute
                if let prev = previousMtime, prev == mtime {
                    // mtime hasn't changed — might be waiting
                    states[sessionId] = .needsAttention
                } else {
                    states[sessionId] = .activelyWorking
                }
            } else if timeSinceModified < 3600 {
                states[sessionId] = .idleWaiting
            } else if timeSinceModified < 86400 {
                states[sessionId] = .ended
            } else {
                states[sessionId] = .stale
            }
        }

        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        // Check hook-based detection first
        guard let lastEvent = lastEvents[sessionId] else {
            return .stale
        }

        switch lastEvent.eventName {
        case "UserPromptSubmit", "SessionStart":
            return .activelyWorking
        case "Stop":
            // Stop is the definitive signal — immediately needs attention
            return .needsAttention
        case "SessionEnd":
            return .ended
        case "Notification":
            return .needsAttention
        default:
            let timeSince = Date.now.timeIntervalSince(lastEvent.timestamp)
            if timeSince < 60 { return .activelyWorking }
            if timeSince < 3600 { return .idleWaiting }
            return .ended
        }
    }

    /// Resolve all pending stops (call periodically from background orchestrator).
    public func resolvePendingStops() -> [String] {
        let now = Date.now
        var resolved: [String] = []
        for (sessionId, stopTime) in pendingStops {
            if now.timeIntervalSince(stopTime) >= stopDelay {
                resolved.append(sessionId)
            }
        }
        for id in resolved {
            pendingStops.removeValue(forKey: id)
        }
        return resolved
    }
}
