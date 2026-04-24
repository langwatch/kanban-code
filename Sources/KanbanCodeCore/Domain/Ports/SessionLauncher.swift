import Foundation

/// Port for launching and resuming AI CLI sessions.
public protocol SessionLauncher: Sendable {
    /// Launch a new session with a prompt in a project directory.
    func launch(
        sessionName: String,
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?,
        extraEnv: [String: String],
        commandOverride: String?,
        skipPermissions: Bool,
        preamble: String?,
        assistant: CodingAssistant,
        service: APIService?
    ) async throws -> String // returns tmux session name

    /// Resume an existing session by its ID.
    func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?,
        extraEnv: [String: String],
        commandOverride: String?,
        skipPermissions: Bool,
        preamble: String?,
        assistant: CodingAssistant,
        service: APIService?
    ) async throws -> String // returns tmux session name
}

/// Default parameter extension so callers that don't need all params aren't broken.
extension SessionLauncher {
    public func launch(
        sessionName: String,
        projectPath: String,
        prompt: String,
        worktreeName: String?,
        shellOverride: String?
    ) async throws -> String {
        try await launch(
            sessionName: sessionName,
            projectPath: projectPath,
            prompt: prompt,
            worktreeName: worktreeName,
            shellOverride: shellOverride,
            extraEnv: [:],
            commandOverride: nil,
            skipPermissions: false,
            preamble: nil,
            assistant: .claude,
            service: nil
        )
    }

    public func resume(
        sessionId: String,
        projectPath: String,
        shellOverride: String?,
        extraEnv: [String: String] = [:],
        commandOverride: String? = nil
    ) async throws -> String {
        try await resume(
            sessionId: sessionId,
            projectPath: projectPath,
            shellOverride: shellOverride,
            extraEnv: extraEnv,
            commandOverride: commandOverride,
            skipPermissions: false,
            preamble: nil,
            assistant: .claude,
            service: nil
        )
    }
}
