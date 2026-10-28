import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KanbanCodeCore
import KanbanCodeRemoteKit

/// A file attached to a composer that is not an image. Its upload to the
/// machine where the card's assistant runs starts when it is attached.
struct PromptFileAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading(Double)
        case ready(String)
        case failed(String)
    }

    let id: String
    let name: String
    let size: Int64
    let localURL: URL
    var state: State

    var readyPath: String? {
        if case .ready(let path) = state { return path }
        return nil
    }
}

/// The files of every composer, by draft key: `PromptFileDrafts.mainKey`
/// for a card's Main chat, `conversationKey` for a conversation. Window
/// drops, pastes and the attach button all add here, so the composer that
/// shows the draft finds them.
@MainActor @Observable
final class PromptFileDrafts {
    static let shared = PromptFileDrafts()

    private(set) var files: [String: [PromptFileAttachment]] = [:]
    @ObservationIgnored private var uploads: [String: Task<Void, Never>] = [:]

    static func mainKey(cardId: String) -> String { "main/" + cardId }
    static func conversationKey(cardId: String, conversationId: String) -> String { cardId + "/" + conversationId }

    func attachments(_ key: String) -> [PromptFileAttachment] { files[key] ?? [] }

    func isUploading(_ key: String) -> Bool {
        attachments(key).contains { if case .uploading = $0.state { return true }; return false }
    }

    /// Attaches files to the composer of `key` and starts sending each to
    /// the machine where the card's assistant runs.
    func add(_ urls: [URL], cardId: String, key: String) {
        for url in urls {
            let name = PromptFiles.safeName(url.lastPathComponent)
            let size = (try? PromptFileReader.size(of: url)) ?? 0
            var attachment = PromptFileAttachment(id: UUID().uuidString, name: name, size: size, localURL: url, state: .uploading(0))
            if size > PromptFiles.maxBytes {
                attachment.state = .failed(PromptFiles.tooLargeMessage(name: name, size: size))
                files[key, default: []].append(attachment)
                continue
            }
            files[key, default: []].append(attachment)
            let id = attachment.id
            uploads[id] = Task { [weak self] in
                do {
                    let path = try await AppComposition.shared.engine.attachPromptFile(cardId: cardId, fileURL: url) { sent, total in
                        let fraction = total > 0 ? Double(sent) / Double(total) : 1
                        Task { @MainActor in self?.update(id, key: key, .uploading(fraction)) }
                    }
                    self?.update(id, key: key, .ready(path))
                } catch is CancellationError {
                    return
                } catch {
                    KanbanCodeLog.warn("chat", "Could not attach \(name) to card \(cardId): \(error)")
                    self?.update(id, key: key, .failed(error.localizedDescription))
                }
                self?.uploads[id] = nil
            }
        }
    }

    private func update(_ id: String, key: String, _ state: PromptFileAttachment.State) {
        guard let index = files[key]?.firstIndex(where: { $0.id == id }) else { return }
        // A late progress report never takes back a finished upload.
        if case .uploading = state, let current = files[key]?[index].state {
            guard case .uploading = current else { return }
        }
        files[key]?[index].state = state
    }

    func remove(_ id: String, key: String) {
        uploads[id]?.cancel()
        uploads[id] = nil
        files[key]?.removeAll { $0.id == id }
        if files[key]?.isEmpty == true { files[key] = nil }
    }

    /// The paths of the files to put in the prompt, and clears the draft.
    /// Nil while a file is still uploading.
    func takeReadyPaths(_ key: String) -> [String]? {
        guard !isUploading(key) else { return nil }
        let paths = attachments(key).compactMap(\.readyPath)
        files[key] = nil
        return paths
    }

    /// Splits dropped or pasted file URLs into images, which go inline as
    /// before, and the files that go as paths.
    static func partition(_ urls: [URL]) -> (images: [URL], files: [URL]) {
        var images: [URL] = []
        var others: [URL] = []
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue, PromptFiles.isImage(fileName: url.lastPathComponent) {
                images.append(url)
            } else if !isDirectory.boolValue {
                others.append(url)
            }
        }
        return (images, others)
    }

    /// Asks for files with the open panel, then attaches them.
    func pick(cardId: String, key: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Attach files to the message"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        add(panel.urls, cardId: cardId, key: key)
    }
}

/// The SF Symbol for a file, by its type.
func promptFileSymbol(_ name: String) -> String {
    guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .sourceCode) || type.conforms(to: .plainText) || type.conforms(to: .json) { return "doc.text" }
    return "doc"
}

/// A file chip in a composer: icon, name, size, upload state, remove.
struct PromptFileChip: View {
    let attachment: PromptFileAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: promptFileSymbol(attachment.name))
                .font(.app(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.app(.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.app(.caption2))
                    .foregroundStyle(isFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .leading)
            if case .uploading(let fraction) = attachment.state {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
        .accessibilityIdentifier("promptFileChip")
    }

    private var isFailed: Bool {
        if case .failed = attachment.state { return true }
        return false
    }

    private var detail: String {
        let size = PromptFiles.formattedSize(attachment.size)
        switch attachment.state {
        case .uploading(let fraction): return "\(size), sending \(Int(fraction * 100))%"
        case .ready: return size
        case .failed(let message): return message
        }
    }

    private var help: String {
        switch attachment.state {
        case .ready(let path): return path
        case .failed(let message): return message
        case .uploading: return attachment.localURL.path
        }
    }
}

/// The file chips of a sent message, from its `[File: ...]` lines. A click
/// shows the file in Finder when it is on this Mac, else copies its path.
struct SentFileChips: View {
    let paths: [String]

    var body: some View {
        if !paths.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    SentFileChip(path: path)
                }
            }
        }
    }
}

private struct SentFileChip: View {
    let path: String

    private var expanded: String { (path as NSString).expandingTildeInPath }
    private var isLocal: Bool { FileManager.default.fileExists(atPath: expanded) }

    var body: some View {
        Button {
            if isLocal {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: promptFileSymbol(path))
                    .font(.app(size: 13))
                    .foregroundStyle(.secondary)
                Text(PromptFiles.displayName(of: path))
                    .font(.app(.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = localSize {
                    Text(PromptFiles.formattedSize(size))
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(isLocal ? "Show in Finder: \(path)" : "Copy path: \(path)")
    }

    private var localSize: Int64? {
        guard isLocal else { return nil }
        return try? PromptFileReader.size(of: URL(fileURLWithPath: expanded))
    }
}
