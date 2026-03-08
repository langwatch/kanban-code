import Foundation

/// Detects Gemini CLI session activity using both hooks and file modification time polling.
///
/// Hook events (AfterAgent, BeforeAgent, SessionStart, SessionEnd, Notification)
/// are normalized to canonical names by the orchestrator before reaching here.
/// File polling provides fallback for sessions started before hooks were installed.
public actor GeminiActivityDetector: ActivityDetector {
    /// Cached activity states from the last poll.
    private var polledStates: [String: ActivityState] = [:]

    /// Hook-based states: tracks the last hook event per session.
    private var hookStates: [String: ActivityState] = [:]

    /// Timestamp of the last hook event per session (for timeout detection).
    private var lastEventTime: [String: Date] = [:]

    /// Thresholds (seconds) for activity detection.
    private let activeThreshold: TimeInterval   // < this = activelyWorking
    private let attentionThreshold: TimeInterval // < this = needsAttention

    public init(activeThreshold: TimeInterval = 120, attentionThreshold: TimeInterval = 300) {
        self.activeThreshold = activeThreshold
        self.attentionThreshold = attentionThreshold
    }

    // MARK: - ActivityDetector

    /// Handle hook events from Gemini CLI.
    /// Event names are already normalized (AfterAgent→Stop, BeforeAgent→UserPromptSubmit).
    public func handleHookEvent(_ event: HookEvent) async {
        lastEventTime[event.sessionId] = event.timestamp

        switch HookManager.normalizeEventName(event.eventName) {
        case "UserPromptSubmit":
            hookStates[event.sessionId] = .activelyWorking
        case "SessionStart":
            hookStates[event.sessionId] = .idleWaiting
        case "Stop":
            hookStates[event.sessionId] = .needsAttention
        case "SessionEnd":
            hookStates[event.sessionId] = .ended
        case "Notification":
            hookStates[event.sessionId] = .needsAttention
        default:
            break
        }
    }

    /// Poll session file mtimes and return activity states.
    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        let fileManager = FileManager.default
        var states: [String: ActivityState] = [:]

        for (sessionId, path) in sessionPaths {
            // Prefer hook-based state if available and recent
            if let hookState = hookStates[sessionId] {
                // Check for timeout: if actively working for >5 minutes without a new event, downgrade
                if hookState == .activelyWorking,
                   let lastTime = lastEventTime[sessionId],
                   Date.now.timeIntervalSince(lastTime) > attentionThreshold {
                    hookStates[sessionId] = .needsAttention
                    states[sessionId] = .needsAttention
                } else {
                    states[sessionId] = hookState
                }
                continue
            }

            // Fall back to file polling
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                states[sessionId] = .ended
                continue
            }

            let timeSinceModified = Date.now.timeIntervalSince(mtime)

            if timeSinceModified < activeThreshold {
                states[sessionId] = .activelyWorking
            } else if timeSinceModified < attentionThreshold {
                states[sessionId] = .needsAttention
            } else if timeSinceModified < 3600 {
                states[sessionId] = .idleWaiting
            } else if timeSinceModified < 86400 {
                states[sessionId] = .ended
            } else {
                states[sessionId] = .stale
            }
        }

        // Cache for activityState(for:) lookups
        for (id, state) in states {
            polledStates[id] = state
        }

        return states
    }

    /// Return the cached activity state for a given session.
    public func activityState(for sessionId: String) async -> ActivityState {
        return hookStates[sessionId] ?? polledStates[sessionId] ?? .stale
    }
}
