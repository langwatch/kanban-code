import Foundation

public actor MastracodeActivityDetector: ActivityDetector {
    private var polledStates: [String: ActivityState] = [:]
    private var hookStates: [String: ActivityState] = [:]
    private var lastEventTime: [String: Date] = [:]

    private let activeThreshold: TimeInterval
    private let attentionThreshold: TimeInterval

    public init(activeThreshold: TimeInterval = 120, attentionThreshold: TimeInterval = 300) {
        self.activeThreshold = activeThreshold
        self.attentionThreshold = attentionThreshold
    }

    public func handleHookEvent(_ event: HookEvent) async {
        lastEventTime[event.sessionId] = event.timestamp

        switch HookManager.normalizeEventName(event.eventName) {
        case "UserPromptSubmit":
            hookStates[event.sessionId] = .activelyWorking
        case "SessionStart":
            hookStates[event.sessionId] = .idleWaiting
        case "Stop", "Notification":
            hookStates[event.sessionId] = .needsAttention
        case "SessionEnd":
            hookStates[event.sessionId] = .ended
        default:
            break
        }
    }

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        var states: [String: ActivityState] = [:]

        for (sessionId, sessionPath) in sessionPaths {
            if let hookState = effectiveHookState(for: sessionId) {
                states[sessionId] = hookState
                continue
            }

            guard let resolved = MastracodeSessionPath.decode(sessionPath),
                  let updatedAt = try? MastracodeDatabase.readUpdatedAt(
                    databasePath: resolved.databasePath,
                    threadId: resolved.threadId
                  ),
                  let updatedDate = makeFractionalISO8601Formatter().date(from: updatedAt)
                    ?? ISO8601DateFormatter().date(from: updatedAt) else {
                states[sessionId] = .ended
                continue
            }

            let age = Date.now.timeIntervalSince(updatedDate)
            if age < activeThreshold {
                states[sessionId] = .activelyWorking
            } else if age < attentionThreshold {
                states[sessionId] = .needsAttention
            } else if age < 3600 {
                states[sessionId] = .idleWaiting
            } else if age < 86400 {
                states[sessionId] = .ended
            } else {
                states[sessionId] = .stale
            }
        }

        for (sessionId, state) in states {
            polledStates[sessionId] = state
        }
        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        effectiveHookState(for: sessionId) ?? polledStates[sessionId] ?? .stale
    }

    private func effectiveHookState(for sessionId: String) -> ActivityState? {
        guard let hookState = hookStates[sessionId] else { return nil }
        if hookState == .activelyWorking,
           let eventTime = lastEventTime[sessionId],
           Date.now.timeIntervalSince(eventTime) > attentionThreshold {
            hookStates[sessionId] = .needsAttention
            return .needsAttention
        }
        return hookState
    }
}
