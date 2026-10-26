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
struct CardActionsMenuActions {
    let onStart: () -> Void
    let onResume: () -> Void
    let onFork: (_ keepWorktree: Bool) -> Void
    let onRenameRequest: () -> Void
    let onSetPinned: (_ isPinned: Bool) -> Void
    let onSetSelfCompactContextThreshold: (_ thresholdTokens: Int?) -> Void
    let onCopyResumeCmd: () -> Void
    let onCopyConversationMarkdown: () -> Void
    /// Opens the record of prompts sent to this card. Nil where there is no
    /// place to present it from.
    let onShowPromptHistory: (() -> Void)?
    /// Opens the card's vault releases and leases.
    let onShowVault: (() -> Void)?
    let subagentCount: Int
    let onShowSubagents: () -> Void
    let onTrimSession: () -> Void
    let onCheckpoint: (() -> Void)?
    let onAddLink: (() -> Void)?
    let onUnlink: ((Action.LinkType) -> Void)?
    let onDiscover: (() -> Void)?
    let onCleanupWorktree: (() -> Void)?
    let canCleanupWorktree: Bool
    let onArchive: (() -> Void)?
    let onDelete: () -> Void
    let onMoveToProject: (String) -> Void
    let onMoveToFolder: () -> Void
    let onMigrateAssistant: (CodingAssistant) -> Void

    init(
        onStart: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onFork: @escaping (_ keepWorktree: Bool) -> Void,
        onRenameRequest: @escaping () -> Void,
        onSetPinned: @escaping (_ isPinned: Bool) -> Void,
        onSetSelfCompactContextThreshold: @escaping (_ thresholdTokens: Int?) -> Void,
        onCopyResumeCmd: @escaping () -> Void,
        onCopyConversationMarkdown: @escaping () -> Void,
        subagentCount: Int,
        onShowSubagents: @escaping () -> Void,
        onTrimSession: @escaping () -> Void,
        onCheckpoint: (() -> Void)?,
        onAddLink: (() -> Void)?,
        onUnlink: ((Action.LinkType) -> Void)?,
        onDiscover: (() -> Void)?,
        onCleanupWorktree: (() -> Void)?,
        canCleanupWorktree: Bool,
        onArchive: (() -> Void)?,
        onDelete: @escaping () -> Void,
        onMoveToProject: @escaping (String) -> Void,
        onMoveToFolder: @escaping () -> Void,
        onMigrateAssistant: @escaping (CodingAssistant) -> Void,
        onShowPromptHistory: (() -> Void)? = nil,
        onShowVault: (() -> Void)? = nil
    ) {
        self.onStart = onStart
        self.onResume = onResume
        self.onFork = onFork
        self.onRenameRequest = onRenameRequest
        self.onSetPinned = onSetPinned
        self.onSetSelfCompactContextThreshold = onSetSelfCompactContextThreshold
        self.onCopyResumeCmd = onCopyResumeCmd
        self.onCopyConversationMarkdown = onCopyConversationMarkdown
        self.subagentCount = subagentCount
        self.onShowSubagents = onShowSubagents
        self.onTrimSession = onTrimSession
        self.onCheckpoint = onCheckpoint
        self.onAddLink = onAddLink
        self.onUnlink = onUnlink
        self.onDiscover = onDiscover
        self.onCleanupWorktree = onCleanupWorktree
        self.canCleanupWorktree = canCleanupWorktree
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.onMoveToProject = onMoveToProject
        self.onMoveToFolder = onMoveToFolder
        self.onMigrateAssistant = onMigrateAssistant
        self.onShowPromptHistory = onShowPromptHistory
        self.onShowVault = onShowVault
    }
}

struct CardActionsMenu: View {
    let card: KanbanCodeCard
    let actions: CardActionsMenuActions
    var showBranchInfo = false
    var githubBaseURL: String?

    var availableProjects: [(name: String, path: String)] = []
    var enabledAssistants: [CodingAssistant] = []

    var body: some View {
        let catalog = CardActionCatalog(
            card: card,
            actions: actions,
            showBranchInfo: showBranchInfo,
            githubBaseURL: githubBaseURL,
            availableProjects: availableProjects,
            enabledAssistants: enabledAssistants,
            environment: .live(for: card)
        )
        let sections = catalog.sections
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                switch item.kind {
                case .perform(let run):
                    button(item, run: run)
                case .submenu(let children):
                    Menu {
                        ForEach(children) { child in
                            if child.dividerBefore { Divider() }
                            if case .perform(let run) = child.kind {
                                button(child, run: run)
                            }
                        }
                    } label: {
                        label(item)
                    }
                }
            }
        }
    }

    private func button(_ item: CardActionItem, run: @escaping () -> Void) -> some View {
        Button(role: item.isDestructive ? .destructive : nil, action: run) {
            label(item)
        }
        .disabled(item.isDisabled)
    }

    @ViewBuilder
    private func label(_ item: CardActionItem) -> some View {
        if item.isChecked {
            HStack {
                Text(item.title)
                Image(systemName: "checkmark")
            }
        } else if let icon = item.icon {
            Label(item.title, systemImage: icon)
        } else {
            Text(item.title)
        }
    }
}

enum DetailTab: String, CaseIterable {
    case terminal, history, issue, pullRequest, prompt

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .history: "History"
        case .issue: "Issue"
        case .pullRequest: "Pull Request"
        case .prompt: "Prompt"
        }
    }

    /// The tabs a card offers: the terminal and the history always, the
    /// others when the card has the link behind them. The prompt tab stands
    /// aside for the issue, which carries the same text.
    static func available(for card: KanbanCodeCard) -> [DetailTab] {
        var tabs: [DetailTab] = [.terminal, .history]
        if card.link.issueLink != nil { tabs.append(.issue) }
        if !card.link.prLinks.isEmpty { tabs.append(.pullRequest) }
        if card.link.promptBody != nil && card.link.issueLink == nil { tabs.append(.prompt) }
        return tabs
    }

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

    static func load(cardId: String) -> ChatDraft? {
        let path = (dirPath as NSString).appendingPathComponent("\(cardId).json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let draft = try? JSONDecoder().decode(ChatDraft.self, from: data),
              !draft.isEmpty else {
            return nil
        }
        return draft
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
    var heading = "Rename Session"
    var placeholder = "Session name"
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)

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
            // Reached by keyboard, so it opens ready to type. The old name is
            // selected rather than left behind the caret, because a rename
            // replaces it far more often than it edits it.
            nameFocused = true
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
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
                onSubmit: save,
                onEscape: { isPresented = false }
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
