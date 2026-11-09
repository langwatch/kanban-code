import Foundation

extension MasterEngine {
    /// `GH_TOKEN` of the GitHub account the Claude account claiming `path`
    /// names, for a card's local session. Empty when there is none.
    func gitHubEnvironment(_ path: String) async -> [String: String] {
        await GitHubAccountTokens.shared.environment(forPath: path, layout: ClaudeConfigDirectories.current)
    }
}
