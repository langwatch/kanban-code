import Foundation

/// GitHub integration via the `gh` CLI tool.
public final class GhCliAdapter: PRTrackerPort, @unchecked Sendable {
    private let ghPath: String

    public init() {
        self.ghPath = ShellCommand.findExecutable("gh") ?? "gh"
    }

    public func fetchPRs(repoRoot: String) async throws -> [String: PullRequest] {
        KanbanCodeLog.info("gh", "fetchPRs for \(repoRoot)")
        let result = try await ShellCommand.run(
            ghPath,
            arguments: [
                "pr", "list", "--state", "all", "--limit", "50",
                "--json", "number,title,state,url,headRefName,reviewDecision",
            ],
            currentDirectory: repoRoot
        )

        guard result.succeeded, !result.stdout.isEmpty else {
            KanbanCodeLog.warn("gh", "fetchPRs failed or empty for \(repoRoot): exit=\(result.exitCode) stderr=\(result.stderr.prefix(200))")
            return [:]
        }
        guard let data = result.stdout.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var prs: [String: PullRequest] = [:]
        for item in items {
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let state = item["state"] as? String,
                  let url = item["url"] as? String,
                  let headRefName = item["headRefName"] as? String else {
                continue
            }

            let reviewDecision = item["reviewDecision"] as? String
            let pr = PullRequest(
                number: number,
                title: title,
                state: state.lowercased() == "merged" ? "merged" : state.lowercased(),
                url: url,
                headRefName: headRefName,
                reviewDecision: reviewDecision
            )
            // Prefer open PRs over closed/merged for the same branch
            if let existing = prs[headRefName] {
                if pr.state == "open" && existing.state != "open" {
                    prs[headRefName] = pr
                }
                // Otherwise keep existing (first match)
            } else {
                prs[headRefName] = pr
            }
        }

        return prs
    }

    public func enrichPRDetails(repoRoot: String, prs: inout [String: PullRequest]) async throws {
        let openPRs = prs.values.filter { $0.state == "open" }
        guard !openPRs.isEmpty else { return }

        // Build GraphQL query with aliases for each PR
        var queryParts: [String] = []
        var aliasMap: [String: String] = [:] // alias → branch

        for (i, pr) in openPRs.enumerated() {
            let alias = "pr\(i)"
            aliasMap[alias] = pr.headRefName
            queryParts.append("""
            \(alias): pullRequest(number: \(pr.number)) {
              body
              reviewDecision
              mergeStateStatus
              reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { url } } } }
              reviews(states: APPROVED) { totalCount }
              commits(last: 1) { nodes { commit { statusCheckRollup {
                state
                contexts(first: 50) { nodes {
                  ... on CheckRun { name status conclusion }
                  ... on StatusContext { context state }
                } }
              } } } }
            }
            """)
        }

        // Get repo owner/name
        let repoResult = try await ShellCommand.run(
            ghPath,
            arguments: ["repo", "view", "--json", "owner,name"],
            currentDirectory: repoRoot
        )
        guard repoResult.succeeded,
              let repoData = repoResult.stdout.data(using: .utf8),
              let repoInfo = try? JSONSerialization.jsonObject(with: repoData) as? [String: Any],
              let owner = repoInfo["owner"] as? [String: Any],
              let ownerLogin = owner["login"] as? String,
              let repoName = repoInfo["name"] as? String else {
            return
        }

        let query = """
        query {
          repository(owner: "\(ownerLogin)", name: "\(repoName)") {
            \(queryParts.joined(separator: "\n"))
          }
        }
        """

        let graphqlResult = try await ShellCommand.run(
            ghPath,
            arguments: ["api", "graphql", "-f", "query=\(query)"],
            currentDirectory: repoRoot
        )

        guard graphqlResult.succeeded,
              let gqlData = graphqlResult.stdout.data(using: .utf8),
              let gqlRoot = try? JSONSerialization.jsonObject(with: gqlData) as? [String: Any],
              let dataObj = gqlRoot["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any] else {
            return
        }

        for (alias, branch) in aliasMap {
            guard var pr = prs[branch],
                  let prData = repo[alias] as? [String: Any] else {
                continue
            }

            // PR body
            if let body = prData["body"] as? String, !body.isEmpty {
                pr.body = body
            }

            // Review decision
            if let decision = prData["reviewDecision"] as? String {
                pr.reviewDecision = decision
            }

            // Merge state status
            if let mergeState = prData["mergeStateStatus"] as? String {
                pr.mergeStateStatus = mergeState
            }

            // Approval count
            if let reviews = prData["reviews"] as? [String: Any],
               let totalCount = reviews["totalCount"] as? Int {
                pr.approvalCount = totalCount
            }

            // Unresolved threads + first unresolved comment URL
            if let threads = prData["reviewThreads"] as? [String: Any],
               let nodes = threads["nodes"] as? [[String: Any]] {
                let unresolved = nodes.filter { ($0["isResolved"] as? Bool) == false }
                pr.unresolvedThreads = unresolved.count
                // Grab URL of the first unresolved thread's first comment
                if let firstThread = unresolved.first,
                   let comments = firstThread["comments"] as? [String: Any],
                   let commentNodes = comments["nodes"] as? [[String: Any]],
                   let firstComment = commentNodes.first,
                   let url = firstComment["url"] as? String {
                    pr.firstUnresolvedThreadURL = url
                }
            }

            // CI status + individual check runs
            if let commits = prData["commits"] as? [String: Any],
               let commitNodes = commits["nodes"] as? [[String: Any]],
               let lastCommit = commitNodes.last,
               let commit = lastCommit["commit"] as? [String: Any],
               let rollup = commit["statusCheckRollup"] as? [String: Any] {
                // Aggregate state
                if let state = rollup["state"] as? String {
                    switch state.uppercased() {
                    case "SUCCESS": pr.checksStatus = .pass
                    case "FAILURE", "ERROR": pr.checksStatus = .fail
                    case "PENDING": pr.checksStatus = .pending
                    default: break
                    }
                }

                // Individual check runs
                if let contexts = rollup["contexts"] as? [String: Any],
                   let nodes = contexts["nodes"] as? [[String: Any]] {
                    var runs: [CheckRun] = []
                    for node in nodes {
                        if let name = node["name"] as? String {
                            // CheckRun type
                            let status = (node["status"] as? String).flatMap { CheckRunStatus(rawValue: $0.lowercased().replacingOccurrences(of: "_", with: "_")) } ?? .completed
                            let conclusion = (node["conclusion"] as? String).flatMap { CheckRunConclusion(rawValue: $0.lowercased()) }
                            runs.append(CheckRun(name: name, status: status, conclusion: conclusion))
                        } else if let context = node["context"] as? String,
                                  let state = node["state"] as? String {
                            // StatusContext type
                            let conclusion: CheckRunConclusion? = switch state.uppercased() {
                            case "SUCCESS": .success
                            case "FAILURE", "ERROR": .failure
                            case "PENDING": nil
                            default: nil
                            }
                            runs.append(CheckRun(name: context, status: .completed, conclusion: conclusion))
                        }
                    }
                    pr.checkRuns = runs
                }
            }

            prs[branch] = pr
        }
    }

    /// Batch lookup: find PRs by branch name + refresh existing PRs by number.
    /// Single GraphQL call per repo instead of N individual `gh pr` calls.
    public func batchPRLookup(
        repoRoot: String,
        branches: [String],
        prNumbers: [Int]
    ) async throws -> (byBranch: [String: PullRequest], byNumber: [Int: PullRequest]) {
        guard !branches.isEmpty || !prNumbers.isEmpty else { return ([:], [:]) }

        // Get repo owner/name
        let repoResult = try await ShellCommand.run(
            ghPath,
            arguments: ["repo", "view", "--json", "owner,name"],
            currentDirectory: repoRoot
        )
        guard repoResult.succeeded,
              let repoData = repoResult.stdout.data(using: .utf8),
              let repoInfo = try? JSONSerialization.jsonObject(with: repoData) as? [String: Any],
              let owner = repoInfo["owner"] as? [String: Any],
              let ownerLogin = owner["login"] as? String,
              let repoName = repoInfo["name"] as? String else {
            return ([:], [:])
        }

        var queryParts: [String] = []
        var branchAliases: [String: String] = [:] // alias → branch
        var numberAliases: [String: Int] = [:]    // alias → prNumber

        // Branch lookups via pullRequests(headRefName:)
        for (i, branch) in branches.enumerated() {
            let alias = "branch\(i)"
            branchAliases[alias] = branch
            queryParts.append("""
            \(alias): pullRequests(headRefName: "\(branch)", first: 1, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes { number title state url headRefName reviewDecision mergeStateStatus reviews(states: APPROVED) { totalCount } }
            }
            """)
        }

        // PR number lookups
        for (i, number) in prNumbers.enumerated() {
            let alias = "pr\(i)"
            numberAliases[alias] = number
            queryParts.append("""
            \(alias): pullRequest(number: \(number)) {
              number title state url headRefName reviewDecision mergeStateStatus reviews(states: APPROVED) { totalCount }
            }
            """)
        }

        let query = """
        query {
          repository(owner: "\(ownerLogin)", name: "\(repoName)") {
            \(queryParts.joined(separator: "\n"))
          }
        }
        """

        let result = try await ShellCommand.run(
            ghPath,
            arguments: ["api", "graphql", "-f", "query=\(query)"],
            currentDirectory: repoRoot
        )

        // GraphQL may return partial data + errors, or fail entirely.
        // Parse whatever data we can get; if total failure, retry individually.
        let combined = result.stderr + result.stdout
        if combined.localizedCaseInsensitiveContains("rate limit") || combined.contains("RATE_LIMITED") {
            KanbanCodeLog.warn("gh", "batchPRLookup hit rate limit")
            throw GhCliError.rateLimited
        }

        // Try to parse response (may have partial data even with errors)
        let data = result.stdout.data(using: .utf8)
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let dataObj = root?["data"] as? [String: Any]
        let repo = dataObj?["repository"] as? [String: Any]

        // If batch failed entirely (e.g. one bad PR number breaks the query),
        // retry each PR number individually so one bad apple doesn't block all.
        if repo == nil && !numberAliases.isEmpty {
            KanbanCodeLog.warn("gh", "batchPRLookup GraphQL failed, retrying PRs individually: \(result.stderr.prefix(200))")
            var byBranch: [String: PullRequest] = [:]
            var byNumber: [Int: PullRequest] = [:]

            // Retry branches as a single batch (they rarely fail)
            if !branchAliases.isEmpty {
                let branchQuery = "query { repository(owner: \"\(ownerLogin)\", name: \"\(repoName)\") { \(branchAliases.map { alias, branch in "\(alias): pullRequests(headRefName: \"\(branch)\", first: 1, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number title state url headRefName reviewDecision mergeStateStatus reviews(states: APPROVED) { totalCount } } }" }.joined(separator: "\n")) } }"
                let brResult = try? await ShellCommand.run(ghPath, arguments: ["api", "graphql", "-f", "query=\(branchQuery)"], currentDirectory: repoRoot)
                if let brData = brResult?.stdout.data(using: .utf8),
                   let brRoot = try? JSONSerialization.jsonObject(with: brData) as? [String: Any],
                   let brRepo = (brRoot["data"] as? [String: Any])?["repository"] as? [String: Any] {
                    for (alias, branch) in branchAliases {
                        guard let container = brRepo[alias] as? [String: Any],
                              let nodes = container["nodes"] as? [[String: Any]],
                              let item = nodes.first,
                              let pr = parsePRFromGraphQL(item) else { continue }
                        byBranch[branch] = pr
                    }
                }
            }

            // Retry each PR number individually
            for (_, number) in numberAliases {
                let singleQuery = "query { repository(owner: \"\(ownerLogin)\", name: \"\(repoName)\") { pullRequest(number: \(number)) { number title state url headRefName reviewDecision mergeStateStatus reviews(states: APPROVED) { totalCount } } } }"
                let sResult = try? await ShellCommand.run(ghPath, arguments: ["api", "graphql", "-f", "query=\(singleQuery)"], currentDirectory: repoRoot)
                guard let sData = sResult?.stdout.data(using: .utf8),
                      let sRoot = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                      let sRepo = (sRoot["data"] as? [String: Any])?["repository"] as? [String: Any],
                      let item = sRepo["pullRequest"] as? [String: Any],
                      let pr = parsePRFromGraphQL(item) else {
                    KanbanCodeLog.info("gh", "batchPRLookup: PR #\(number) not found, skipping")
                    continue
                }
                byNumber[number] = pr
            }
            return (byBranch, byNumber)
        }

        guard let repo else {
            KanbanCodeLog.warn("gh", "batchPRLookup GraphQL failed: \(result.stderr.prefix(200))")
            return ([:], [:])
        }

        var byBranch: [String: PullRequest] = [:]
        var byNumber: [Int: PullRequest] = [:]

        for (alias, branch) in branchAliases {
            guard let container = repo[alias] as? [String: Any],
                  let nodes = container["nodes"] as? [[String: Any]],
                  let item = nodes.first else { continue }
            if let pr = parsePRFromGraphQL(item) {
                byBranch[branch] = pr
            }
        }

        for (alias, number) in numberAliases {
            guard let item = repo[alias] as? [String: Any] else { continue }
            if let pr = parsePRFromGraphQL(item) {
                byNumber[number] = pr
            }
        }

        return (byBranch, byNumber)
    }

    private func parsePRFromGraphQL(_ item: [String: Any]) -> PullRequest? {
        guard let number = item["number"] as? Int,
              let title = item["title"] as? String,
              let state = item["state"] as? String,
              let url = item["url"] as? String,
              let headRefName = item["headRefName"] as? String else {
            return nil
        }
        let reviewDecision = item["reviewDecision"] as? String
        let approvalCount = (item["reviews"] as? [String: Any])?["totalCount"] as? Int ?? 0
        let mergeStateStatus = item["mergeStateStatus"] as? String
        return PullRequest(
            number: number,
            title: title,
            state: state.lowercased() == "merged" ? "merged" : state.lowercased(),
            url: url,
            headRefName: headRefName,
            reviewDecision: reviewDecision,
            approvalCount: approvalCount,
            mergeStateStatus: mergeStateStatus
        )
    }

    public func fetchPRBody(repoRoot: String, prNumber: Int) async throws -> String? {
        let result = try await ShellCommand.run(
            ghPath,
            arguments: ["pr", "view", "\(prNumber)", "--json", "body"],
            currentDirectory: repoRoot
        )
        guard result.succeeded, !result.stdout.isEmpty,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? String else {
            return nil
        }
        return body
    }

    public func isAvailable() async -> Bool {
        guard ShellCommand.findExecutable("gh") != nil else { return false }

        // Check auth status
        do {
            let result = try await ShellCommand.run(ghPath, arguments: ["auth", "status"])
            return result.succeeded
        } catch {
            return false
        }
    }

    /// Fetch GitHub issues matching a filter query.
    public func fetchIssues(repoRoot: String, filter: String) async throws -> [GitHubIssue] {
        let filterArgs = filter.split(separator: " ").map(String.init)
        let result = try await ShellCommand.run(
            ghPath,
            arguments: [
                "search", "issues", "--match", "title,body",
                "--json", "number,title,body,url,labels",
                "--limit", "25",
            ] + filterArgs,
            currentDirectory: repoRoot
        )

        guard result.succeeded, !result.stdout.isEmpty else { return [] }
        guard let data = result.stdout.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> GitHubIssue? in
            guard let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["url"] as? String else {
                return nil
            }
            let body = item["body"] as? String
            let labels = (item["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return GitHubIssue(number: number, title: title, body: body, url: url, labels: labels)
        }
    }

    // MARK: - Issue Creation

    /// Create a new GitHub issue and return its number and URL.
    public func createIssue(repoRoot: String, title: String, body: String?) async throws -> (number: Int, url: String) {
        var arguments = ["issue", "create", "--title", title]
        if let body, !body.isEmpty {
            arguments += ["--body", body]
        }

        let result = try await ShellCommand.run(
            ghPath,
            arguments: arguments,
            currentDirectory: repoRoot
        )
        guard result.succeeded, !result.stdout.isEmpty else {
            throw GhCliError.commandFailed(result.stderr)
        }
        // gh issue create prints the URL on stdout (e.g. "https://github.com/owner/repo/issues/42\n")
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract issue number from URL
        guard let lastComponent = url.split(separator: "/").last,
              let number = Int(lastComponent) else {
            throw GhCliError.commandFailed("Failed to parse issue number from: \(url)")
        }
        return (number: number, url: url)
    }

    /// Merge a PR using the configured merge command template.
    /// The template can contain `${number}` which gets replaced with the PR number.
    public func mergePR(repoRoot: String, prNumber: Int, commandTemplate: String) async throws -> MergeResult {
        let expanded = commandTemplate.replacingOccurrences(of: "${number}", with: "\(prNumber)")
        let parts = expanded.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return .failure("Invalid merge command") }

        // Resolve the executable (first part, e.g. "gh")
        let executable = ShellCommand.findExecutable(parts[0]) ?? parts[0]
        let arguments = Array(parts.dropFirst())

        let result = try await ShellCommand.run(
            executable,
            arguments: arguments,
            currentDirectory: repoRoot
        )
        KanbanCodeLog.info("merge", "gh merge exit=\(result.exitCode) stdout=[\(result.stdout.prefix(200))] stderr=[\(result.stderr.prefix(200))]")
        let output = (result.stdout + " " + result.stderr).lowercased()
        let mergeSucceeded = result.succeeded
            || output.contains("merged")
            || (output.contains("pull request") && output.contains("merge"))
            || (output.contains("delete") && output.contains("branch")) // branch delete fail implies merge succeeded
        if mergeSucceeded {
            let warning = result.succeeded ? nil : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(warning: warning)
        } else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(msg)
        }
    }
}

public enum MergeResult: Sendable {
    case success(warning: String? = nil)
    case failure(String)
}

public enum GhCliError: Error, LocalizedError {
    case rateLimited
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "GitHub API rate limit exceeded — pausing PR lookups for 5 minutes"
        case .commandFailed(let message):
            return message
        }
    }
}

/// A GitHub issue for the backlog.
public struct GitHubIssue: Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let body: String?
    public let url: String
    public let labels: [String]
}
