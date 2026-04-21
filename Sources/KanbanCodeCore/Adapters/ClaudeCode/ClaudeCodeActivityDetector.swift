import Foundation

/// Detects Claude Code session activity from hook events and .jsonl file polling.
public actor ClaudeCodeActivityDetector: ActivityDetector {
    /// Stores the last known event per session.
    private var lastEvents: [String: HookEvent] = [:]
    /// Stores the last known mtime per session (for polling fallback).
    private var lastMtimes: [String: Date] = [:]
    /// Stores the last polled activity state per session.
    private var polledStates: [String: ActivityState] = [:]
    /// Session transcript paths (populated by pollActivity, used for direct mtime checks).
    private var sessionPaths: [String: String] = [:]
    /// Sessions that received a Stop but might get a follow-up prompt.
    private var pendingStops: [String: Date] = [:]
    /// Last time UserPromptSubmit was seen per session — survives later Stop/Notification events.
    /// Used by Stop/Notification handlers to tell "mid-conversation" from "dormant session".
    private var lastUserPromptTimes: [String: Date] = [:]
    /// Delay before treating a Stop as final (seconds).
    private let stopDelay: TimeInterval

    public init(stopDelay: TimeInterval = 3.0, activeTimeout: TimeInterval = 300) {
        self.stopDelay = stopDelay
        self.activeTimeout = activeTimeout
    }

    public func handleHookEvent(_ event: HookEvent) async {
        lastEvents[event.sessionId] = event

        if event.eventName == "Stop" {
            // Record stop — will be resolved after stopDelay if no follow-up prompt
            pendingStops[event.sessionId] = event.timestamp
        } else if event.eventName == "UserPromptSubmit" {
            // Clear pending stops on any new activity
            pendingStops.removeValue(forKey: event.sessionId)
            lastUserPromptTimes[event.sessionId] = event.timestamp
        } else if event.eventName == "SessionStart" {
            pendingStops.removeValue(forKey: event.sessionId)
        }
    }

    /// Timeout (seconds) before treating a hook-active session as timed out.
    /// Matches Claude Code's own ~5-minute timeout for long-running tool calls.
    private let activeTimeout: TimeInterval

    public func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] {
        // Cache paths for direct mtime checks in activityState()
        for (id, path) in sessionPaths {
            self.sessionPaths[id] = path
        }

        let fileManager = FileManager.default
        var states: [String: ActivityState] = [:]

        for (sessionId, path) in sessionPaths {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                states[sessionId] = .ended
                continue
            }

            lastMtimes[sessionId] = mtime

            let timeSinceModified = Date.now.timeIntervalSince(mtime)

            // Polling NEVER returns .activelyWorking — only hooks can confirm active work.
            // This prevents false "In Progress" cards for sessions started externally.
            if timeSinceModified < activeTimeout {
                // Modified within timeout window — session might be active but unconfirmed by hooks
                states[sessionId] = .idleWaiting
            } else if timeSinceModified < 3600 {
                // No activity for 5min-1hr — likely needs attention
                states[sessionId] = .needsAttention
            } else if timeSinceModified < 86400 {
                states[sessionId] = .ended
            } else {
                states[sessionId] = .stale
            }
        }

        // Store poll results for use by activityState(for:)
        for (id, state) in states {
            polledStates[id] = state
        }

        return states
    }

    public func activityState(for sessionId: String) async -> ActivityState {
        // Check hook-based detection first
        guard let lastEvent = lastEvents[sessionId] else {
            // No hook events — use polled state if available.
            // Polling never returns .activelyWorking, so sessions without hooks
            // never appear in "In Progress".
            return polledStates[sessionId] ?? .stale
        }

        switch lastEvent.eventName {
        case "UserPromptSubmit":
            // After a prompt, Claude is actively working. Stay in this state until:
            // 1. A Stop hook fires (handled by the "Stop" case below)
            // 2. File stale >3s AND last jsonl line is "[Request interrupted by user]"
            //    → Ctrl+C detected instantly without waiting for 5-minute timeout
            // 3. File hasn't been modified for >5 minutes (safety net timeout)
            //    Handles: killed process, Claude's own tool timeout, abandoned sessions
            // 4. No file path cached (shouldn't happen) — fall back to hook age
            guard let path = sessionPaths[sessionId] else {
                let timeSince = Date.now.timeIntervalSince(lastEvent.timestamp)
                if timeSince > activeTimeout {
                    return polledStates[sessionId] ?? .needsAttention
                }
                return .activelyWorking
            }

            guard let fileAge = Self.fileAge(path) else {
                return .activelyWorking
            }

            // Safety net: 5-minute timeout for killed processes / abandoned sessions
            if fileAge > activeTimeout {
                return .needsAttention
            }

            // Fast Ctrl+C detection: file stopped changing >3s ago, check last line
            if fileAge > 3, Self.lastLineContainsInterrupt(path) {
                return .needsAttention
            }

            return .activelyWorking

        case "SessionStart":
            // Session opened or resumed — Claude is at the prompt waiting for input.
            // NOT actively working yet (that requires UserPromptSubmit).
            return .idleWaiting

        case "Stop":
            // Stop is the authoritative "turn ended" signal from Claude Code.
            // BUT: ralph loops and fast human replies fire a new UserPromptSubmit
            // within 1-2 seconds of Stop, and demoting for a few hundred ms
            // before the next prompt causes a visible Waiting ↔ In Progress
            // flicker. Use a short grace period (`stopDelay`) where we keep
            // showing activelyWorking; after that, snap to needsAttention.
            let sinceStop = Date.now.timeIntervalSince(lastEvent.timestamp)
            if sinceStop < stopDelay {
                return .activelyWorking
            }
            // Continuation detection: ralph-loop (and similar stop-hook
            // continuation frameworks) inject `additionalContext` on Stop,
            // so Claude runs another turn WITHOUT firing a new UserPromptSubmit.
            // The only signal we have is the transcript file being written to
            // after the Stop event. If mtime advanced past the Stop timestamp,
            // Claude is still working.
            if let path = sessionPaths[sessionId],
               let fileAge = Self.fileAge(path),
               fileAge < activeTimeout {
                let fileMtime = Date.now.addingTimeInterval(-fileAge)
                if fileMtime.timeIntervalSince(lastEvent.timestamp) > 1.0 {
                    return .activelyWorking
                }
            }
            return .needsAttention
        case "SessionEnd":
            return .ended
        case "Notification":
            // Notification fires when Claude wants user attention (tool
            // approval, bash permission prompt, etc). Default to
            // needsAttention unless the transcript is still being written to
            // very recently — which indicates the user just auto-approved and
            // Claude is already resuming work.
            if let path = sessionPaths[sessionId],
               let fileAge = Self.fileAge(path),
               fileAge < 5 {
                return .activelyWorking
            }
            return .needsAttention
        default:
            // Unknown hook events — use polled state, never promote to activelyWorking
            return polledStates[sessionId] ?? .idleWaiting
        }
    }

    /// Quick mtime check — returns seconds since file was last modified, or nil on error.
    private static func fileAge(_ path: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date.now.timeIntervalSince(mtime)
    }

    /// Check if the last line of a .jsonl file contains "[Request interrupted by user]".
    /// Claude Code writes this synthetic user message on Ctrl+C.
    /// Reads from the end of the file for efficiency (avoids reading entire file).
    private static func lastLineContainsInterrupt(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        // Read the last 4KB — enough for the last jsonl line
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(4096, fileSize)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.availableData
        guard let tail = String(data: data, encoding: .utf8) else { return false }

        // Find the last non-empty line
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        guard let lastLine = lines.last else { return false }

        return lastLine.contains("Request interrupted by user")
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
