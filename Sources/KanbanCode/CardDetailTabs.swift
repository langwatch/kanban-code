import SwiftUI
import KanbanCodeCore
import MarkdownUI

// MARK: - Issue Tab View

struct IssueTabView: View {
    let issue: IssueLink
    let cardTitle: String
    let githubBaseURL: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header: title + number + open button
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title ?? cardTitle)
                            .font(.app(.headline))
                            .textSelection(.enabled)
                        Text(verbatim: "#\(issue.number)")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = resolvedIssueURL(issue, githubBaseURL: githubBaseURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in Browser", systemImage: "arrow.up.right.square")
                                .font(.app(.caption))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // Markdown body
                if let body = issue.body, !body.isEmpty {
                    Markdown(body)
                        .markdownTheme(.compact)
                        .textSelection(.enabled)
                } else {
                    Text("No description provided.")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Pull Request Tab View

struct PRTabView: View {
    let card: KanbanCodeCard
    let githubBaseURL: String?

    @State private var prBody: String?
    @State private var isLoadingPRBody = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(card.link.prLinks.enumerated()), id: \.element.number) { index, pr in
                    if index > 0 { Divider().padding(.vertical, 4) }

                    // Header: title + badge
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pr.title ?? "Pull Request")
                            .font(.app(.headline))
                            .textSelection(.enabled)
                        HStack {
                            PRBadge(status: pr.status, prNumber: pr.number)
                            Spacer()
                            if let url = resolvedPRURL(pr, githubBaseURL: githubBaseURL) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Open in Browser", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // CI Check Runs
                    if let checks = pr.checkRuns, !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Checks")
                                .font(.app(.subheadline, weight: .bold))
                                .foregroundStyle(.secondary)
                            ForEach(checks, id: \.name) { check in
                                HStack(spacing: 6) {
                                    checkRunIcon(check)
                                    Text(check.name)
                                        .font(.app(.caption))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Reviews summary
                    if pr.approvalCount != nil || pr.unresolvedThreads != nil {
                        HStack(spacing: 16) {
                            if let approvals = pr.approvalCount, approvals > 0 {
                                Label("\(approvals) approval\(approvals == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                                    .font(.app(.caption))
                                    .foregroundStyle(.green)
                            }
                            if let unresolved = pr.unresolvedThreads, unresolved > 0 {
                                Label("\(unresolved) unresolved", systemImage: "bubble.left.fill")
                                    .font(.app(.caption))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Divider()

                // PR Body (lazy loaded — shows primary PR body)
                if isLoadingPRBody {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading PR description...")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let body = prBody ?? card.link.prLink?.body, !body.isEmpty {
                    Markdown(htmlToMarkdownImages(body))
                        .markdownTheme(.compact)
                        .textSelection(.enabled)
                } else {
                    Text("No description provided.")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(16)
        }
        .task(id: card.id) {
            await loadPRBody()
        }
    }

    private func loadPRBody() async {
        guard let pr = card.link.prLink,
              let projectPath = card.link.projectPath else { return }
        isLoadingPRBody = true
        do {
            let body = try await GhCliAdapter().fetchPRBody(repoRoot: projectPath, prNumber: pr.number)
            prBody = body
        } catch {
            KanbanCodeLog.error("detail", "PR #\(pr.number) body failed: \(error)")
        }
        isLoadingPRBody = false
    }
}

// MARK: - Prompt Tab View

struct PromptTabView: View {
    let card: KanbanCodeCard
    var onCopyToast: ((String) -> Void)?
    @Binding var showEditPromptSheet: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prompt")
                        .font(.app(.subheadline, weight: .bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        if let body = card.link.promptBody {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(body, forType: .string)
                            onCopyToast?("Copied prompt")
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy prompt")

                    Button { showEditPromptSheet = true } label: {
                        Image(systemName: "pencil")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")
                }

                if let body = card.link.promptBody {
                    Text(body)
                        .font(.sessionDetail())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Attached images
                if let imagePaths = card.link.promptImagePaths, !imagePaths.isEmpty {
                    Text("Images")
                        .font(.app(.subheadline, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(imagePaths, id: \.self) { path in
                        if let nsImage = NSImage(contentsOfFile: path) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 400, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - PR Summary Pill

struct PRSummaryPill: View {
    let prLinks: [PRLink]
    let primary: PRLink

    var body: some View {
        let totalApprovals = prLinks.compactMap(\.approvalCount).reduce(0, +)
        let totalThreads = prLinks.compactMap(\.unresolvedThreads).reduce(0, +)
        let targetURL = totalThreads > 0
            ? (primary.firstUnresolvedThreadURL ?? primary.url)
            : primary.url

        if totalApprovals > 0 || totalThreads > 0 {
            Button {
                if let urlStr = targetURL, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    if totalApprovals > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark")
                                .font(.app(size: 10, weight: .bold))
                            Text(verbatim: "\(totalApprovals)")
                                .font(.app(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    }
                    if totalThreads > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left")
                                .font(.app(size: 10))
                            Text(verbatim: "\(totalThreads)")
                                .font(.app(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .frame(height: 36)
                .padding(.horizontal, 10)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .modifier(HoverBrightness())
            .help(totalThreads > 0 ? "Open unresolved comment" : "Open pull request")
        }
    }
}

// MARK: - Merge Button

struct MergeButton: View {
    let pr: PRLink
    let projectPath: String?
    var onMerged: ((Int) -> Void)?
    var onToast: ((String) -> Void)?

    @State private var isMerging = false
    @State private var mergeError: String?
    @State private var showBlockedPopover = false

    private var isMergeable: Bool {
        guard let ms = pr.mergeStateStatus?.uppercased() else { return false }
        return ms == "CLEAN" || ms == "UNSTABLE" || ms == "HAS_HOOKS"
    }

    private var mergeBlockedReason: String? {
        guard let ms = pr.mergeStateStatus?.uppercased() else { return nil }
        switch ms {
        case "CLEAN", "UNSTABLE", "HAS_HOOKS": return nil
        case "BLOCKED": return "Blocked by branch protection rules"
        case "BEHIND": return "Branch is behind the base branch and needs to be updated"
        case "DIRTY": return "Merge conflicts must be resolved first"
        case "DRAFT": return "Pull request is still a draft"
        case "UNKNOWN": return "GitHub is still calculating merge status"
        default: return "Merge state: \(ms.lowercased())"
        }
    }

    private var isMergeStatusLoading: Bool {
        pr.mergeStateStatus == nil
    }

    var body: some View {
        let canMerge = isMergeable
        let loading = isMergeStatusLoading
        let blocked = mergeBlockedReason
        if canMerge {
            // Mergeable — green button
            Button {
                guard !isMerging, let repoRoot = projectPath else { return }
                isMerging = true
                mergeError = nil
                Task {
                    let gh = GhCliAdapter()
                    let settings = try await SettingsStore().read()
                    let result = try await gh.mergePR(repoRoot: repoRoot, prNumber: pr.number, commandTemplate: settings.github.mergeCommand)
                    isMerging = false
                    switch result {
                    case .success(let warning):
                        onToast?("PR #\(pr.number) merged")
                        onMerged?(pr.number)
                        if let warning, !warning.isEmpty {
                            KanbanCodeLog.info("merge", "PR #\(pr.number) merged with warning: \(warning)")
                        }
                    case .failure(let msg):
                        mergeError = msg
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isMerging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.merge")
                    }
                    Text("Merge")
                }
                .font(.app(size: 13))
                .foregroundStyle(Color.green.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.green.opacity(0.08), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(HoverFeedbackStyle())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .disabled(isMerging)
            .help("Merge pull request")
            .popover(isPresented: .init(get: { mergeError != nil }, set: { if !$0 { mergeError = nil } })) {
                if let err = mergeError {
                    Text(err)
                        .font(.app(.caption))
                        .padding(8)
                        .frame(maxWidth: 300)
                }
            }
        } else if loading {
            // Still loading merge status — gray with spinner, click opens PR on GitHub
            Button {
                if let url = pr.url.flatMap({ URL(string: $0 + "#partial-timeline") }) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Merge")
                }
                .font(.app(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.secondary.opacity(0.06), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(HoverFeedbackStyle())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .help("Loading merge status… Click to open PR on GitHub")
        } else {
            // Blocked — gray button with reason popover + clickable to open PR
            VStack(spacing: 0) {
                Button {
                    if let url = pr.url.flatMap({ URL(string: $0 + "#partial-timeline") }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "nosign")
                        Text("Merge")
                    }
                    .font(.app(size: 13))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.secondary.opacity(0.06), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(HoverFeedbackStyle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .onHover { showBlockedPopover = $0 }

                // Invisible anchor below the button — popover opens downward, away from button
                Color.clear
                    .frame(width: 0, height: 0)
                    .popover(isPresented: $showBlockedPopover, arrowEdge: .bottom) {
                        if let reason = blocked {
                            Text(reason)
                                .font(.app(.caption))
                                .padding(8)
                                .frame(maxWidth: 300)
                                .fixedSize()
                        }
                    }
            }
        }
    }
}

// MARK: - PR Helper Functions

func checkRunIcon(_ check: CheckRun) -> some View {
    Group {
        switch check.status {
        case .completed:
            switch check.conclusion {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .neutral, .skipped:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .cancelled, .timedOut, .actionRequired:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case nil:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .inProgress:
            Image(systemName: "clock.fill")
                .foregroundStyle(.yellow)
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }
    .font(.app(.caption))
}

func resolvedIssueURL(_ issue: IssueLink, githubBaseURL: String?) -> URL? {
    let urlString = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
    return urlString.flatMap { URL(string: $0) }
}

func resolvedPRURL(_ pr: PRLink, githubBaseURL: String?) -> URL? {
    let urlString = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
    return urlString.flatMap { URL(string: $0) }
}

/// Convert HTML img tags to Markdown image syntax so MarkdownUI can render them.
func htmlToMarkdownImages(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(
        pattern: #"<img\s+[^>]*?src\s*=\s*"([^"]+)"[^>]*?/?>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) else { return text }

    var result = text
    let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

    // Replace in reverse order to preserve ranges
    for match in matches.reversed() {
        guard let fullRange = Range(match.range, in: result),
              let srcRange = Range(match.range(at: 1), in: result) else { continue }
        let src = String(result[srcRange])

        // Try to extract alt text
        var alt = "image"
        if let altRegex = try? NSRegularExpression(pattern: #"alt\s*=\s*"([^"]*)""#, options: .caseInsensitive),
           let altMatch = altRegex.firstMatch(in: String(result[fullRange]), range: NSRange(0..<result[fullRange].count)),
           let altRange = Range(altMatch.range(at: 1), in: String(result[fullRange])) {
            let extracted = String(String(result[fullRange])[altRange])
            if !extracted.isEmpty { alt = extracted }
        }

        result.replaceSubrange(fullRange, with: "![\(alt)](\(src))")
    }

    return result
}
