import SwiftUI
import KanbanCodeCore
import MarkdownUI

/// Shared between CardDetailView and ContentView so the toolbar can show
/// the exact same actions menu without duplicating the menu builder.
final class ActionsMenuProvider {
    var builder: (() -> NSMenu)?
}

/// Unified context menu content for all card action menus (kanban cards,
/// list sidebar, drawer toolbar). Ensures every entry point shows the same
/// actions with the same state.
struct CardActionsMenu: View {
    let card: KanbanCodeCard
    var showBranchInfo = false
    var githubBaseURL: String?

    // Actions
    var onStart: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: (_ keepWorktree: Bool) -> Void = { _ in }
    var onRenameRequest: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onCheckpoint: (() -> Void)?
    var onAddLink: (() -> Void)?
    var onUnlink: ((Action.LinkType) -> Void)?
    var onDiscover: (() -> Void)?
    var onCleanupWorktree: (() -> Void)?
    var canCleanupWorktree: Bool = true
    var onArchive: (() -> Void)?
    var onDelete: () -> Void = {}
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    var onMoveToFolder: () -> Void = {}
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (CodingAssistant) -> Void = { _ in }

    var body: some View {
        // Branch / PR / Issue info (expanded detail only)
        if showBranchInfo {
            branchSection
        }

        // Primary actions
        primaryActions

        Divider()

        // Copy section
        copySection

        // Links section (Open PR / Issue)
        linksSection

        // Discover Branch
        if let onDiscover, card.link.sessionLink != nil || card.link.worktreeLink != nil {
            Divider()
            Button(action: onDiscover) {
                Label("Discover Branch", systemImage: "arrow.triangle.pull")
            }
        }

        // Cleanup Worktree
        if let onCleanupWorktree, card.link.worktreeLink != nil, canCleanupWorktree {
            Divider()
            Button(role: .destructive, action: onCleanupWorktree) {
                Label("Cleanup Worktree", systemImage: "trash")
            }
        }

        // Move / Migrate submenus
        moveAndMigrateSection

        // Delete / Archive
        Divider()
        if card.link.manuallyArchived {
            if card.link.source != .githubIssue {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Card", systemImage: "trash")
                }
            }
        } else if let onArchive {
            Button(action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }
        } else {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Card", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var branchSection: some View {
        if let branch = card.link.worktreeLink?.branch ?? card.link.discoveredBranches?.first, !branch.isEmpty {
            Menu {
                Button("Copy Branch Name") { copyToClipboard(branch) }
                if card.link.worktreeLink != nil, let onUnlink {
                    Button("Unlink Branch") { onUnlink(.worktree) }
                }
            } label: {
                Label("Branch: \(branch)", systemImage: "arrow.triangle.branch")
            }
        }
        ForEach(card.link.prLinks, id: \.number) { pr in
            let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
            Menu {
                if let url = pr.url.flatMap({ URL(string: $0) }) {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                Button("Copy PR Number") { copyToClipboard("#\(String(pr.number))") }
                if let onUnlink {
                    Button("Unlink PR") { onUnlink(.pr(number: pr.number)) }
                }
            } label: {
                Label("PR: #\(String(pr.number))\(detail)", systemImage: "arrow.triangle.pull")
            }
        }
        if let issue = card.link.issueLink {
            Menu {
                if let url = (issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }).flatMap({ URL(string: $0) }) {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                Button("Copy Issue Number") { copyToClipboard("#\(String(issue.number))") }
                if let onUnlink {
                    Button("Unlink Issue") { onUnlink(.issue) }
                }
            } label: {
                Label("Issue: #\(String(issue.number))", systemImage: "circle.circle")
            }
        }
        Divider()
    }

    @ViewBuilder
    private var primaryActions: some View {
        if card.column == .backlog {
            Button(action: onStart) {
                Label("Start", systemImage: "play.fill")
            }
        }
        if card.column != .backlog {
            Button(action: onResume) {
                Label("Resume Session", systemImage: "play.fill")
            }
        }
        Button(action: { onFork(true) }) {
            Label("Fork Session", systemImage: "arrow.branch")
        }
        .disabled(card.link.sessionLink?.sessionPath == nil)

        Button(action: onRenameRequest) {
            Label("Rename", systemImage: "pencil")
        }

        if let onCheckpoint {
            Button(action: onCheckpoint) {
                Label("Checkpoint / Restore", systemImage: "clock.arrow.circlepath")
            }
            .disabled(card.link.sessionLink?.sessionPath == nil)
        }
    }

    @ViewBuilder
    private var copySection: some View {
        Button(action: onCopyResumeCmd) {
            Label("Copy Resume Command", systemImage: "doc.on.doc")
        }
        Button { copyToClipboard(card.id) } label: {
            Label("Copy Card ID", systemImage: "number")
        }
        if let sessionId = card.link.sessionLink?.sessionId {
            Button { copyToClipboard(sessionId) } label: {
                Label("Copy Session ID", systemImage: "desktopcomputer")
            }
        }
        if let sessionPath = card.link.sessionLink?.sessionPath {
            Button { copyToClipboard(sessionPath) } label: {
                Label("Copy Session .jsonl Path", systemImage: "doc.text")
            }
        }
        if let tmux = card.link.tmuxLink?.sessionName {
            Button { copyToClipboard("tmux attach -t \(tmux)") } label: {
                Label("Copy Tmux Command", systemImage: "terminal")
            }
        }
        if let projectPath = card.link.projectPath {
            Button { copyToClipboard(projectPath) } label: {
                Label("Copy Project Path", systemImage: "folder.badge.gearshape")
            }
        }
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            Button { copyToClipboard(worktreePath) } label: {
                Label("Copy Worktree Path", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        if !card.link.prLinks.isEmpty || card.link.issueLink != nil || onAddLink != nil {
            Divider()
            ForEach(card.link.prLinks, id: \.number) { pr in
                Button {
                    if let url = pr.url.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open PR #\(String(pr.number))", systemImage: "arrow.up.right.square")
                }
            }
            if let issue = card.link.issueLink {
                Button {
                    if let url = (issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }).flatMap({ URL(string: $0) }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Issue #\(String(issue.number))", systemImage: "arrow.up.right.square")
                }
            }
            if let onAddLink {
                Button(action: onAddLink) {
                    Label("Add Link", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var moveAndMigrateSection: some View {
        if card.link.sessionLink != nil {
            let currentPath = card.link.projectPath
            let otherProjects = availableProjects.filter { $0.path != currentPath }
            Divider()
            Menu {
                ForEach(otherProjects, id: \.path) { project in
                    Button(project.name) { onMoveToProject(project.path) }
                }
                if !otherProjects.isEmpty { Divider() }
                Button("Select Folder...") { onMoveToFolder() }
            } label: {
                Label("Move to Project", systemImage: "folder.badge.arrow.forward")
            }
        }
        if card.link.sessionLink != nil {
            let migrationTargets = enabledAssistants.filter { $0 != card.link.effectiveAssistant }
            if !migrationTargets.isEmpty {
                Divider()
                Menu {
                    ForEach(migrationTargets, id: \.rawValue) { target in
                        Button(target.displayName) { onMigrateAssistant(target) }
                    }
                } label: {
                    Label("Migrate to Assistant", systemImage: "arrow.triangle.swap")
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum DetailTab: String {
    case terminal, history, issue, pullRequest, prompt

    static func initialTab(for card: KanbanCodeCard) -> DetailTab {
        if card.link.tmuxLink != nil { return .terminal }
        if card.link.sessionLink != nil { return .terminal }
        if card.link.issueLink != nil { return .issue }
        if !card.link.prLinks.isEmpty { return .pullRequest }
        if card.link.promptBody != nil { return .prompt }
        return .terminal
    }
}

/// Button style that provides hover (brighten) and press (dim + scale) feedback
/// for custom-styled plain buttons.
struct HoverFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverableBody(configuration: configuration)
    }

    private struct HoverableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .onHover { isHovered = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// View modifier that adds hover brightness feedback (for Menu and other non-Button views).
struct HoverBrightness: ViewModifier {
    var amount: Double = 0.06
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? amount : 0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Per-card chat draft (persisted to disk)

struct ChatDraft: Codable {
    var text: String = ""
    var images: [Data] = [] // PNG data for attached images

    var isEmpty: Bool { text.isEmpty && images.isEmpty }

    private static let dirPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/chat-drafts")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func loadAll() -> [String: ChatDraft] {
        let dir = dirPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var result: [String: ChatDraft] = [:]
        for file in files where file.hasSuffix(".json") {
            let cardId = String(file.dropLast(5)) // remove .json
            let path = (dir as NSString).appendingPathComponent(file)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let draft = try? JSONDecoder().decode(ChatDraft.self, from: data) {
                if !draft.isEmpty {
                    result[cardId] = draft
                }
            }
        }
        return result
    }

    static func save(cardId: String, draft: ChatDraft) {
        let path = (dirPath as NSString).appendingPathComponent("\(cardId).json")
        if draft.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            if let data = try? JSONEncoder().encode(draft) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - Session ID Row

struct SessionIdRow: View {
    let sessionId: String
    let assistant: CodingAssistant
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    .foregroundStyle(Color.primary.opacity(0.4))
                Text(sessionId)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sessionId, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

// MARK: - Copyable Row

struct CopyableRow: View {
    let icon: String
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Label(text, systemImage: icon)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

// MARK: - Compact Markdown Theme

@MainActor
extension Theme {
    /// Smaller text, tighter spacing, no opaque background on code blocks.
    static let compact = Theme()
        .text { FontSize(.em(0.87)) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.82))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.25)); FontWeight(.semibold) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.12)); FontWeight(.semibold) }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.0)); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.8))
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
}

// MARK: - Rename Dialogs

/// Native rename dialog sheet.
struct RenameSessionDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}

/// Rename dialog for terminal tabs.
struct TabRenameItem: Identifiable {
    let id = UUID()
    let sessionName: String
    let currentName: String
}

struct QueuedPromptItem: Identifiable {
    let id = UUID()
    let existingPrompt: QueuedPrompt?
}

struct RenameTerminalTabDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Terminal Tab")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Tab name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}

// MARK: - NSMenuButton (SwiftUI button that shows an NSMenu anchored below it)

/// A SwiftUI view that renders custom SwiftUI content but on click shows an NSMenu
/// anchored directly below the view — no mouse-position hacks needed.
struct NSMenuButton<Label: View>: NSViewRepresentable {
    let label: Label
    let menuItems: () -> NSMenu

    init(@ViewBuilder label: () -> Label, menuItems: @escaping () -> NSMenu) {
        self.label = label()
        self.menuItems = menuItems
    }

    func makeNSView(context: Context) -> NSMenuButtonNSView {
        let view = NSMenuButtonNSView()
        view.menuBuilder = menuItems
        // Embed the SwiftUI label as a hosting view
        let host = NSHostingView(rootView: label)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ nsView: NSMenuButtonNSView, context: Context) {
        nsView.menuBuilder = menuItems
        // Update SwiftUI label
        if let host = nsView.subviews.first as? NSHostingView<Label> {
            host.rootView = label
        }
    }
}

final class NSMenuButtonNSView: NSView {
    var menuBuilder: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        // Anchor below this view — nil positioning avoids pre-selecting an item
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }
}

// MARK: - NSMenu closure helper

final class NSMenuActionItem: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

extension NSMenu {
    @discardableResult
    func addActionItem(_ title: String, image: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let target = NSMenuActionItem(handler)
        let item = NSMenuItem(title: title, action: #selector(NSMenuActionItem.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target // prevent dealloc
        if let image, let img = NSImage(systemSymbolName: image, accessibilityDescription: nil) {
            item.image = img
        }
        addItem(item)
        return item
    }
}

// MARK: - Edit Prompt Sheet

struct EditPromptSheet: View {
    @Binding var isPresented: Bool
    @State private var text: String
    @State private var images: [ImageAttachment]
    let existingImagePaths: [String]
    let onSave: (String, [ImageAttachment]) -> Void

    init(isPresented: Binding<Bool>, body: String, existingImagePaths: [String], onSave: @escaping (String, [ImageAttachment]) -> Void) {
        self._isPresented = isPresented
        self._text = State(initialValue: body)
        self.existingImagePaths = existingImagePaths
        self.onSave = onSave
        let loaded = existingImagePaths.compactMap { ImageAttachment.fromPath($0) }
        self._images = State(initialValue: loaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            PromptSection(
                text: $text,
                images: $images,
                placeholder: "Describe what you want Claude to do...",
                maxHeight: 300,
                onSubmit: save
            )

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Separate: images that already have a persistent path vs new ones
        var allImages: [ImageAttachment] = []
        for img in images {
            if let path = img.tempPath, existingImagePaths.contains(path) {
                // Already persisted — pass through as-is
                allImages.append(img)
            } else {
                allImages.append(img)
            }
        }
        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), allImages)
        isPresented = false
    }
}
