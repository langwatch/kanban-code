import Foundation
import Observation
import UIKit
import KanbanCodeRemoteKit

/// What is typed and attached for one card, kept per Mac and card until it
/// is sent: across leaving the card, switching tabs and relaunching the app.
/// Stashes set a message aside for later, as rush's ctrl+s does.
///
/// Each image has an `[Image #N]` marker in the text where it goes, as in
/// Claude Code and the Mac composer. Markers are numbered in text order,
/// and deleting one drops its image.
///
/// Other files (a video, a PDF, a zip) upload as soon as they are picked to
/// the machine where the card's assistant runs, and the prompt names each
/// one on a `[File: /path]` line after the text.
@Observable
final class ComposerDraft {
    let key: String
    var text: String {
        didSet {
            guard text != oldValue else { return }
            if !settling { settleImages() }
            save()
        }
    }
    private(set) var images: [DraftImage]
    @ObservationIgnored private var settling = false
    /// Messages set aside, oldest first.
    private(set) var stashes: [Stash]
    /// Files attached, in the order picked.
    private(set) var files: [DraftFile]
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]

    struct Stash: Codable, Identifiable, Equatable {
        let id: UUID
        /// The text with a `[File: /path]` line per attached file.
        var text: String
        /// JPEGs, as in the composer.
        var images: [Data]
        var at: Date

        /// One line for a menu.
        var preview: String {
            let split = PromptFiles.split(text)
            let line = split.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let images = images.isEmpty ? "" : (images.count == 1 ? "1 image" : "\(images.count) images")
            let files = split.paths.isEmpty ? "" : (split.paths.count == 1 ? "1 file" : "\(split.paths.count) files")
            return [line.isEmpty ? nil : String(line.prefix(60)), images.isEmpty ? nil : images, files.isEmpty ? nil : files]
                .compactMap { $0 }.joined(separator: " + ")
        }
    }

    struct DraftImage: Identifiable, Equatable {
        let id: UUID
        /// JPEG, already scaled down for sending.
        let data: Data
    }

    struct DraftFile: Identifiable, Equatable, Codable {
        enum State: Equatable, Codable {
            /// The share sent so far, 0 to 1.
            case uploading(Double)
            /// The file's path where the card's assistant runs.
            case ready(String)
            case failed(String)
        }

        let id: UUID
        var name: String
        /// Nil for a file that came back from a sent or stashed message.
        var size: Int64?
        var state: State

        var remotePath: String? {
            if case .ready(let path) = state { return path }
            return nil
        }
    }

    /// Images are scaled so their long side is at most this, then sent as JPEG.
    static let maxImageSide: CGFloat = 2048

    private let directory: URL?

    init(server: UUID, cardId: String) {
        key = "\(server.uuidString)|\(cardId)"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = base?.appendingPathComponent("drafts", isDirectory: true)
            .appendingPathComponent(Self.fileSafe(key), isDirectory: true)
        let savedText = UserDefaults.standard.string(forKey: Self.textKey(key)) ?? ""
        let savedImages = Self.loadImages(from: directory)
        text = Self.withMarkers(savedText, imageCount: savedImages.count)
        images = savedImages
        stashes = Self.loadStashes(from: directory)
        files = Self.loadFiles(from: directory)
    }

    /// A draft that is never saved, for previews.
    init(preview text: String = "") {
        key = "preview"
        directory = nil
        self.text = text
        images = []
        stashes = []
        files = []
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty
    }

    /// Every file is uploaded, so the message can go.
    var filesReady: Bool { files.allSatisfy { $0.remotePath != nil } }

    /// The paths of the uploaded files, in the order picked.
    var filePaths: [String] { files.compactMap(\.remotePath) }

    /// The prompt as sent: `text` with a line per uploaded file.
    func outgoingText(_ text: String) -> String {
        PromptFiles.appending(paths: filePaths, to: text)
    }

    // MARK: Files

    /// Adds a file being uploaded and returns its id.
    @discardableResult
    func addFile(name: String, size: Int64?) -> UUID {
        let file = DraftFile(id: UUID(), name: name, size: size, state: .uploading(0))
        files.append(file)
        return file.id
    }

    func setFileProgress(_ id: UUID, sent: Int64, total: Int64) {
        guard let index = files.firstIndex(where: { $0.id == id }), case .uploading = files[index].state else { return }
        files[index].state = .uploading(total > 0 ? min(1, max(0, Double(sent) / Double(total))) : 1)
    }

    func finishFile(_ id: UUID, path: String) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].state = .ready(path)
        saveFiles()
    }

    func failFile(_ id: UUID, message: String) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].state = .failed(message)
    }

    /// Drops a file, stopping its upload.
    func removeFile(_ id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        files.removeAll { $0.id == id }
        saveFiles()
    }

    /// Attaches a file picked from Files and uploads it to where the card's
    /// assistant runs. The file is first copied to a temporary folder, so
    /// the picker's access ending does not cut the upload. Returns why it
    /// cannot be attached, or nil once it is on its way.
    func attachFile(at url: URL, client: RemoteClient, cardId: String) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        let name = PromptFiles.safeName(url.lastPathComponent)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let size = values?.fileSize.map(Int64.init) ?? (try? PromptFileReader.size(of: url))
        let refusal: String?
        if values?.isDirectory == true {
            refusal = "\(name) is a folder. Zip it to attach it."
        } else if let size {
            refusal = size > PromptFiles.maxBytes ? PromptFiles.tooLargeMessage(name: name, size: size) : nil
        } else {
            refusal = "\(name) could not be read."
        }
        if let refusal {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return refusal
        }
        let id = addFile(name: name, size: size)
        uploads[id] = Task { [weak self] in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("prompt-files", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let copy = try await Task.detached {
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: copy)
                    return copy
                }.value
                try Task.checkCancellation()
                let path = try await client.uploadPromptFile(cardId: cardId, fileURL: copy, name: name) { sent, total in
                    Task { @MainActor in self?.setFileProgress(id, sent: sent, total: total) }
                }
                guard !Task.isCancelled else { return }
                self?.finishFile(id, path: path)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failFile(id, message: error.localizedDescription)
            }
            self?.uploads[id] = nil
        }
        return nil
    }

    var canAddImages: Bool { images.count < RemoteImage.maxCount }

    /// Adds a picked or captured image, scaled down and re-encoded as JPEG,
    /// and puts its marker at `offset` characters into the text (the end
    /// when nil). Returns the caret offset right after the marker, or nil
    /// when the image cannot be read or would be too big.
    @discardableResult
    func addImage(_ data: Data, at offset: Int? = nil) -> Int? {
        guard canAddImages, let jpeg = Self.prepare(data) else { return nil }
        let chars = Array(text)
        let position = min(max(offset ?? chars.count, 0), chars.count)
        let before = chars[..<position], after = chars[position...]
        // A number no marker has yet; settling renumbers in text order.
        let marker = PromptImageLayout.marker(for: images.count + 1)
        let lead = before.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trail = after.first?.isWhitespace == true ? "" : " "
        let inserted = lead + marker + trail
        replace(text: String(before) + inserted + String(after),
                images: images + [DraftImage(id: UUID(), data: jpeg)])
        return position + inserted.count
    }

    /// Drops an image and its marker.
    func removeImage(_ id: UUID) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let marker = PromptImageLayout.marker(for: index + 1)
        let stripped = text.replacingOccurrences(of: marker + " ", with: "").replacingOccurrences(of: marker, with: "")
        var remaining = images
        remaining.remove(at: index)
        // Marker numbers above it move down by one.
        let renumbered = PromptImageLayout.parts(in: stripped, imageCount: images.count).map { part -> String in
            guard let i = part.imageIndex else { return part.text }
            return PromptImageLayout.marker(for: i < index ? i + 1 : i)
        }.joined()
        replace(text: renumbered, images: remaining)
    }

    /// A deletion reaching into a marker takes the whole marker, as rush
    /// and Claude Code do. Returns the text that makes and the caret offset
    /// in it, or nil for an edit that does not touch a marker.
    func markerDeletion(to newText: String) -> (text: String, caret: Int)? {
        let old = Array(text), new = Array(newText)
        guard !images.isEmpty, new.count < old.count else { return nil }
        var prefix = 0
        while prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < new.count - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix == new.count else { return nil }
        var lower = prefix, upper = old.count - suffix
        for range in Self.markerRanges(in: old) where range.lowerBound < upper && range.upperBound > lower {
            lower = min(lower, range.lowerBound)
            upper = max(upper, range.upperBound)
        }
        guard lower != prefix || upper != old.count - suffix else { return nil }
        return (String(old[..<lower]) + String(old[upper...]), lower)
    }

    /// Takes the text as the field has it for now, images untouched: the
    /// field shows a change to its text only once its own edit is over.
    func holdText(_ newText: String) {
        settling = true
        text = newText
        settling = false
    }

    func clear() {
        replace(text: "", images: [])
        for task in uploads.values { task.cancel() }
        uploads = [:]
        files = []
        saveFiles()
    }

    /// Puts a message into the composer, as if typed and attached. Its
    /// `[File: /path]` lines come back as uploaded files; files still
    /// uploading stay.
    func load(text: String, images: [Data]) {
        let split = PromptFiles.split(text)
        replace(text: Self.withMarkers(split.text, imageCount: images.count),
                images: images.map { DraftImage(id: UUID(), data: $0) })
        files = files.filter { $0.remotePath == nil } + split.paths.map {
            DraftFile(id: UUID(), name: PromptFiles.displayName(of: $0), size: nil, state: .ready($0))
        }
        saveFiles()
    }

    /// The message a stash keeps: the text with its uploaded files.
    private var stashedText: String {
        filePaths.isEmpty ? text : PromptFiles.appending(paths: filePaths, to: text)
    }

    /// Whether there is anything a stash would keep: files still uploading
    /// stay in the composer.
    private var hasStashable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !filePaths.isEmpty
    }

    /// Sets the composer's message aside and clears the composer. Files
    /// still uploading stay in the composer.
    func stash() {
        guard hasStashable else { return }
        stashes.append(Stash(id: UUID(), text: stashedText, images: images.map(\.data), at: .now))
        saveStashes()
        replace(text: "", images: [])
        files.removeAll { $0.remotePath != nil }
        saveFiles()
    }

    /// Brings a stash back into the composer (the latest when `id` is nil).
    /// Whatever the composer holds is stashed in its place.
    func restore(_ id: UUID? = nil) {
        guard let target = id.flatMap({ id in stashes.first { $0.id == id } }) ?? stashes.last else { return }
        stashes.removeAll { $0.id == target.id }
        if hasStashable {
            stashes.append(Stash(id: UUID(), text: stashedText, images: images.map(\.data), at: .now))
        }
        saveStashes()
        load(text: target.text, images: target.images)
    }

    func deleteStash(_ id: UUID) {
        stashes.removeAll { $0.id == id }
        saveStashes()
    }

    var remoteImages: [RemoteImage] {
        images.map { RemoteImage(bytes: $0.data, mediaType: "image/jpeg") }
    }

    // MARK: Markers

    /// Sets text and images together, then settles them.
    private func replace(text newText: String, images newImages: [DraftImage]) {
        settling = true
        images = newImages
        text = newText
        settling = false
        settleImages(force: true)
    }

    /// Keeps the images to the markers in the text: in marker order, and
    /// none whose marker is gone.
    private func settleImages(force: Bool = false) {
        guard !images.isEmpty else {
            if force { saveImages() }
            return
        }
        let settled: (text: String, images: [DraftImage])
        if PromptImageLayout.referencedImageIndices(in: text, imageCount: images.count).isEmpty {
            settled = (text, [])
        } else {
            settled = PromptImageLayout.arranged(text: text, images: images)
        }
        let changed = settled.images.map(\.id) != images.map(\.id)
        settling = true
        images = settled.images
        if settled.text != text { text = settled.text }
        settling = false
        if changed || force { saveImages() }
    }

    /// Text from before markers, or a message whose images have none,
    /// gets them at the end.
    static func withMarkers(_ text: String, imageCount: Int) -> String {
        guard imageCount > 0,
              PromptImageLayout.referencedImageIndices(in: text, imageCount: imageCount).isEmpty else { return text }
        let markers = (1...imageCount).map { PromptImageLayout.marker(for: $0) }.joined(separator: " ")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? markers + " " : trimmed + " " + markers
    }

    /// Character ranges of the `[Image #N]` markers in `chars`.
    static func markerRanges(in chars: [Character]) -> [Range<Int>] {
        let prefix = Array(PromptImageLayout.markerPrefix)
        var out: [Range<Int>] = []
        var i = 0
        while i + prefix.count < chars.count {
            guard Array(chars[i..<i + prefix.count]) == prefix else {
                i += 1
                continue
            }
            var j = i + prefix.count
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            if j > i + prefix.count, j < chars.count, chars[j] == "]" {
                out.append(i..<j + 1)
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Storage

    private func save() {
        guard directory != nil else { return }
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.textKey(key))
        } else {
            UserDefaults.standard.set(text, forKey: Self.textKey(key))
        }
    }

    private func saveImages() {
        guard let directory else { return }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("images", isDirectory: true)
        try? fm.removeItem(at: folder)
        Self.removeLooseImages(in: directory)
        guard !images.isEmpty else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, image) in images.enumerated() {
            try? image.data.write(to: folder.appendingPathComponent(String(format: "%02d.jpg", index)))
        }
    }

    /// Keeps the uploaded files; one still uploading does not outlive the app.
    private func saveFiles() {
        guard let directory else { return }
        let file = directory.appendingPathComponent("files.json")
        let ready = files.filter { $0.remotePath != nil }
        guard !ready.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ready).write(to: file, options: .atomic)
    }

    private static func loadFiles(from directory: URL?) -> [DraftFile] {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("files.json")) else { return [] }
        return ((try? JSONDecoder().decode([DraftFile].self, from: data)) ?? []).filter { $0.remotePath != nil }
    }

    private func saveStashes() {
        guard let directory else { return }
        let file = directory.appendingPathComponent("stashes.json")
        guard !stashes.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(stashes).write(to: file, options: .atomic)
    }

    private static func loadImages(from directory: URL?) -> [DraftImage] {
        guard let directory else { return [] }
        // Drafts from before images had their own folder keep them loose.
        for folder in [directory.appendingPathComponent("images", isDirectory: true), directory] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            let images = names.filter { $0.hasSuffix(".jpg") }.sorted().compactMap { name in
                (try? Data(contentsOf: folder.appendingPathComponent(name))).map { DraftImage(id: UUID(), data: $0) }
            }
            if !images.isEmpty { return images }
        }
        return []
    }

    private static func removeLooseImages(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func loadStashes(from directory: URL?) -> [Stash] {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("stashes.json")) else { return [] }
        return (try? JSONDecoder().decode([Stash].self, from: data)) ?? []
    }

    private static func textKey(_ key: String) -> String { "draft.text.\(key)" }

    private static func fileSafe(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
    }

    /// Scales the image down and encodes it as JPEG under the server's limit.
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxImageSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= RemoteImage.maxBytes {
                return jpeg
            }
        }
        return nil
    }
}
