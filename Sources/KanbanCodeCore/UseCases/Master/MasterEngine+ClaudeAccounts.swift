import Foundation

extension MasterEngine {
    /// `GH_TOKEN` of the GitHub account the Claude account claiming `path`
    /// names, for a card's local session. Empty when there is none.
    func gitHubEnvironment(_ path: String) async -> [String: String] {
        await platform.gitHubTokens.environment(forPath: path, layout: platform.claudeLayout())
    }

    /// What a card's local session gets for its Claude account: the config
    /// folder, the GitHub token, and the marker that lets an app started
    /// from that session drop them again. Empty off this Mac.
    func accountEnvironment(_ account: ClaudeAccountLaunch, projectPath: String, isRemote: Bool) async -> [String: String] {
        guard !isRemote else { return [:] }
        var env = account.environment.merging(await gitHubEnvironment(projectPath)) { _, new in new }
        // The marker names what Kanban set, so only that is dropped again.
        if !env.isEmpty { env[InheritedSessionEnvironment.accountMarker] = env.keys.sorted().joined(separator: ",") }
        return env
    }

    /// Two shell steps run one after the other, either may be absent.
    nonisolated static func joinedPreamble(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// The `projects/` folder a Claude transcript is in: a configured
    /// config folder's, the folder above a `projects/<key>/<id>.jsonl` path
    /// of one no longer configured, else this master's default. A move or
    /// fork of the transcript stays there, so its resume runs with the
    /// same account.
    func claudeProjectsDirectory(holding sessionPath: String) -> String {
        if let known = platform.claudeLayout().projectsDirectory(containingSession: sessionPath) { return known }
        let projects = ((sessionPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        if (projects as NSString).lastPathComponent == "projects" { return projects }
        return platform.claudeProjectsDirectory
    }
}
