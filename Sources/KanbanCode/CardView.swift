import SwiftUI
import AppKit
import KanbanCodeCore

struct CardView: View {
    let card: KanbanCodeCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onStart: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: (_ keepWorktree: Bool) -> Void = { _ in }
    var onRenameRequest: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onDiscover: () -> Void = {}
    var onCleanupWorktree: () -> Void = {}
    var canCleanupWorktree: Bool = true
    var onArchive: () -> Void = {}
    var onDelete: () -> Void = {}
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    var onMoveToFolder: () -> Void = {}
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (CodingAssistant) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(card.displayTitle)
                .font(.app(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Project + branch + link icons
            HStack(spacing: 4) {
                if let projectName = card.projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                if let branch = card.link.worktreeLink?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            // Bottom row: badge + time + link indicators
            HStack(spacing: 6) {
                if card.link.cardLabel == .session {
                    AssistantIcon(assistant: card.link.effectiveAssistant)
                        .frame(width: CGFloat(14).scaled, height: CGFloat(14).scaled)
                        .foregroundStyle(Color.primary.opacity(0.4))
                } else {
                    CardLabelBadge(label: card.link.cardLabel)
                }

                Text(card.relativeTime)
                    .font(.app(.caption2))
                    .foregroundStyle(.tertiary)

                Spacer()

                CardBadgesRow(card: card)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if card.showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            } else if card.column == .backlog {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.app(size: 10))
                        .foregroundStyle(Color.green.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.08), in: Capsule())
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.borderless)
                .help("Start task")
                .padding(8)
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            CardActionsMenu(
                card: card,
                onStart: onStart,
                onResume: onResume,
                onFork: onFork,
                onRenameRequest: onRenameRequest,
                onCopyResumeCmd: onCopyResumeCmd,
                onDiscover: onDiscover,
                onCleanupWorktree: onCleanupWorktree,
                canCleanupWorktree: canCleanupWorktree,
                onArchive: onArchive,
                onDelete: onDelete,
                availableProjects: availableProjects,
                onMoveToProject: onMoveToProject,
                onMoveToFolder: onMoveToFolder,
                enabledAssistants: enabledAssistants,
                onMigrateAssistant: onMigrateAssistant
            )
        }
    }
}

// MARK: - Session Icon

/// Loads the session mascot PNG from the SPM bundle resource.
struct SessionIcon: View {
    /// When set, pre-sizes the NSImage so Menu Label icon slots respect the dimensions.
    var size: CGFloat?

    private static let sourceImage: NSImage? = {
        guard let url = Bundle.appResources.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources")
                ?? Bundle.appResources.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources") else {
            return nil
        }
        let img = NSImage(contentsOf: url)
        img?.isTemplate = true
        return img
    }()

    /// NSImage suitable for use in NSMenuItem (template for dark mode support).
    static var menuImage: NSImage? { sourceImage }

    var body: some View {
        if let src = Self.sourceImage {
            if let size {
                // Pre-sized image for contexts like Menu Labels that ignore .frame()
                Image(nsImage: Self.resizedForMenu(src, to: size))
            } else {
                Image(nsImage: src)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    /// Resize the source image for use in NSMenuItems. Internal so AssistantIcon can use it.
    static func resizedForMenu(_ img: NSImage, to size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}

// MARK: - Assistant Icon

/// Displays the icon for a coding assistant.
struct AssistantIcon: View {
    let assistant: CodingAssistant

    var body: some View {
        switch assistant {
        case .claude:
            SessionIcon()
        case .gemini:
            GeminiSparkle()
        case .codex:
            CodexIcon()
        }
    }

    /// NSImage for use in NSMenuItems — template mode for dark mode support.
    /// NOTE: The `size` parameter must be applied for Claude too (clawd PNG is high-res).
    /// Do not remove the resize call — without it the menu icon renders at full PNG resolution.
    static func menuImage(for assistant: CodingAssistant, size: CGFloat = 16) -> NSImage? {
        switch assistant {
        case .claude:
            guard let src = SessionIcon.menuImage else { return nil }
            return SessionIcon.resizedForMenu(src, to: size)
        case .gemini:
            return geminiMenuImage(size: size)
        case .codex:
            guard let src = CodexIcon.menuImage else { return nil }
            return SessionIcon.resizedForMenu(src, to: size)
        }
    }

    private static func geminiMenuImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = GeminiSparkle().path(in: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        let bezier = NSBezierPath(cgPath: path.cgPath)
        NSColor.black.setFill()
        bezier.fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

/// Loads the Codex SVG from the SPM bundle resource.
struct CodexIcon: View {
    private static let sourceImage: NSImage? = {
        guard let url = Bundle.appResources.url(
            forResource: "codex",
            withExtension: "svg",
            subdirectory: "Resources"
        ) else {
            return nil
        }
        let img = NSImage(contentsOf: url)
        img?.size = NSSize(width: 24, height: 24)
        img?.isTemplate = true
        return img
    }()

    /// NSImage suitable for use in NSMenuItem (template for dark mode support).
    static var menuImage: NSImage? { sourceImage }

    var body: some View {
        if let src = Self.sourceImage {
            Image(nsImage: src)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "curlybraces")
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

/// The Gemini 4-pointed sparkle/star logo drawn as a SwiftUI Shape.
struct GeminiSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY

        // 4-pointed star with curved concave sides
        let waist: CGFloat = 0.07

        return Path { p in
            // Start at top point
            p.move(to: CGPoint(x: cx, y: 0))

            // Top-right curve to right point
            p.addQuadCurve(
                to: CGPoint(x: w, y: cy),
                control: CGPoint(x: cx + w * waist, y: cy - h * waist)
            )

            // Right curve to bottom point
            p.addQuadCurve(
                to: CGPoint(x: cx, y: h),
                control: CGPoint(x: cx + w * waist, y: cy + h * waist)
            )

            // Bottom-left curve to left point
            p.addQuadCurve(
                to: CGPoint(x: 0, y: cy),
                control: CGPoint(x: cx - w * waist, y: cy + h * waist)
            )

            // Left curve back to top
            p.addQuadCurve(
                to: CGPoint(x: cx, y: 0),
                control: CGPoint(x: cx - w * waist, y: cy - h * waist)
            )

            p.closeSubpath()
        }
    }
}

// MARK: - Card Label Badge

struct CardLabelBadge: View {
    let label: CardLabel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label.rawValue)
            .font(.app(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var color: Color {
        switch label {
        case .session: .orange
        case .worktree: .green
        case .issue: .blue
        case .pr: .purple
        case .task: .gray
        }
    }
}

// MARK: - Rate Limit Badge

struct RateLimitBadge: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.app(size: 8))
            Text("Rate Limited")
                .font(.app(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .foregroundStyle(.orange)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isHovering, arrowEdge: .top) {
            Text("GitHub API rate limit exceeded.\nPR status updates paused for 5 minutes.")
                .font(.app(.caption))
                .padding(8)
                .fixedSize()
        }
    }
}

// MARK: - Card Badges Row (reused by CardView + SearchCardRow)

/// Displays tmux, PR, rate limit, issue, image, and remote indicators for a card.
struct CardBadgesRow: View {
    let card: KanbanCodeCard

    var body: some View {
        // Tmux indicator (green when attached, shows count for 2+)
        if let tmux = card.link.tmuxLink {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.app(.caption2))
                    .foregroundStyle(.green)
                if tmux.terminalCount > 1 {
                    Text(verbatim: "\(tmux.terminalCount)")
                        .font(.app(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
        }

        // PR badge(s) — worst status across all PRs
        if let primary = card.link.prLink {
            let totalThreads = card.link.prLinks.compactMap(\.unresolvedThreads).reduce(0, +)
            PRBadge(status: card.link.worstPRStatus, prNumber: primary.number, unresolvedThreads: totalThreads)
            if card.link.prLinks.count > 1 {
                Text(verbatim: "+\(card.link.prLinks.count - 1)")
                    .font(.app(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }

        // Rate limit badge
        if card.isRateLimited {
            RateLimitBadge()
        }

        // Issue indicator
        if let issue = card.link.issueLink {
            HStack(spacing: 2) {
                Image(systemName: "circle.circle")
                    .font(.app(.caption2))
                Text(verbatim: "\(issue.number)")
                    .font(.app(.caption2))
            }
            .foregroundStyle(.secondary)
        }

        // Image attachment indicator
        if let imgs = card.link.promptImagePaths, !imgs.isEmpty {
            Image(systemName: "photo")
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
        }

        // Remote execution indicator
        if card.link.isRemote {
            Image(systemName: "cloud")
                .font(.app(.caption2))
                .foregroundStyle(.teal)
        }
    }
}
