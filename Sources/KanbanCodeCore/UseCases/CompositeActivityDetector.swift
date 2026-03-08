import Foundation

/// An `ActivityDetector` implementation that routes operations to the correct
/// assistant-specific detector via the registry. Hook events are forwarded to
/// all registered detectors (both Claude and Gemini now have hooks). Polling
/// and state queries fan out to all registered detectors and merge results.
public final class CompositeActivityDetector: ActivityDetector, @unchecked Sendable {
    private let registry: CodingAssistantRegistry

    public init(registry: CodingAssistantRegistry, defaultDetector: ActivityDetector) {
        self.registry = registry
    }

    /// Forward hook events to all registered detectors.
    /// Each detector normalizes event names internally (e.g. Gemini's AfterAgent → Stop),
    /// so events from one assistant are harmless to another's detector.
    public func handleHookEvent(_ event: HookEvent) async {
        for assistant in registry.available {
            if let detector = registry.detector(for: assistant) {
                await detector.handleHookEvent(event)
            }
        }
    }

    /// Poll all registered detectors and merge results.
    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        var merged: [String: ActivityState] = [:]

        for assistant in registry.available {
            guard let detector = registry.detector(for: assistant) else { continue }
            let results = await detector.pollActivity(sessionPaths: sessionPaths)
            // Keep the highest-priority state per session
            for (id, state) in results {
                if let existing = merged[id] {
                    if state.priority > existing.priority {
                        merged[id] = state
                    }
                } else {
                    merged[id] = state
                }
            }
        }

        return merged
    }

    /// Query all registered detectors and return the highest-priority state.
    /// This ensures the correct detector's state wins — e.g. a Gemini session's
    /// `.activelyWorking` from GeminiActivityDetector beats `.idleWaiting` from
    /// ClaudeCodeActivityDetector (which may have stored a shared SessionStart event).
    public func activityState(for sessionId: String) async -> ActivityState {
        var best: ActivityState = .stale
        for assistant in registry.available {
            guard let detector = registry.detector(for: assistant) else { continue }
            let state = await detector.activityState(for: sessionId)
            if state.priority > best.priority {
                best = state
            }
        }
        return best
    }
}
