import SwiftUI
import AppKit

/// Invisible AppKit-based overlay that detects folder drags from Finder.
/// Uses NSView's `registerForDraggedTypes` so it works regardless of SwiftUI's
/// nested `.onDrop` hierarchy (which would otherwise be intercepted by column drop zones).
struct FolderDropZone: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (URL) -> Void

    func makeNSView(context: Context) -> FolderDropNSView {
        let view = FolderDropNSView()
        view.onTargetChanged = { targeted in
            Task { @MainActor in isTargeted = targeted }
        }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: FolderDropNSView, context: Context) {
        view.onDrop = onDrop
    }
}

final class FolderDropNSView: NSView {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL(from: sender) != nil else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        guard let url = folderURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func folderURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }
}

// MARK: - Image/file drop zone (same pattern, for terminal drops)

/// Invisible AppKit-based overlay that detects image/file drags.
/// When an image is dragged over the window and a terminal is open,
/// shows a drop target over the terminal area.
struct ImageDropZone: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (Data) -> Void
    /// Dropped files that are not images.
    var onFileDrop: (([URL]) -> Void)? = nil

    func makeNSView(context: Context) -> ImageDropNSView {
        let view = ImageDropNSView()
        view.onTargetChanged = { targeted in
            Task { @MainActor in isTargeted = targeted }
        }
        view.onDrop = onDrop
        view.onFileDrop = onFileDrop
        return view
    }

    func updateNSView(_ view: ImageDropNSView, context: Context) {
        view.onDrop = onDrop
        view.onFileDrop = onFileDrop
    }
}

final class ImageDropNSView: NSView {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: ((Data) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender.draggingPasteboard) ? .copy : []
    }

    private func accepts(_ pasteboard: NSPasteboard) -> Bool {
        if onFileDrop != nil, !PromptFileDrafts.partition(fileURLs(in: pasteboard)).files.isEmpty { return true }
        return extractImageData(from: pasteboard) != nil
    }

    private func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        if let onFileDrop {
            let split = PromptFileDrafts.partition(fileURLs(in: sender.draggingPasteboard))
            if !split.files.isEmpty {
                onFileDrop(split.files)
                for url in split.images {
                    if let png = Self.pngData(contentsOf: url) { onDrop?(png) }
                }
                return true
            }
        }
        guard let data = extractImageData(from: sender.draggingPasteboard) else { return false }
        onDrop?(data)
        return true
    }

    private static func pngData(contentsOf url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func extractImageData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}
