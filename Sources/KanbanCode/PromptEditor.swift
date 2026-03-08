import SwiftUI
import AppKit

/// A TextEditor replacement where Enter submits and Shift+Enter inserts a newline.
/// Reports its intrinsic height so SwiftUI can auto-size via `fixedSize(horizontal:vertical:)`.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var placeholder: String = ""
    var maxHeight: CGFloat = 400
    var onSubmit: () -> Void = {}
    var onImagePaste: ((Data) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PromptEditorScrollView {
        let scrollView = PromptEditorScrollView(maxHeight: maxHeight)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmitTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onImagePaste = onImagePaste

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: PromptEditorScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        // Only push text from binding when user is NOT actively editing.
        // When the user types, textDidChange pushes to the binding. If a parent
        // re-render (e.g. card reconciliation) calls updateNSView before SwiftUI
        // processes the binding update, `text` can be stale. Setting textView.string
        // with stale text resets the cursor to the end.
        let isEditing = textView.window?.firstResponder === textView
        if textView.string != text && !isEditing {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.onImagePaste = onImagePaste
        textView.font = font

        // Update placeholder
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(textView)

        // Recalculate intrinsic height after text/font changes
        scrollView.recalcIntrinsicHeight()
    }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var placeholder: String = ""

        init(_ parent: PromptEditor) {
            self.parent = parent
            self.placeholder = parent.placeholder
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder(textView)
            // Recalculate height when user types
            (textView.enclosingScrollView as? PromptEditorScrollView)?.recalcIntrinsicHeight()
        }

        func updatePlaceholder(_ textView: NSTextView) {
            if textView.string.isEmpty && !placeholder.isEmpty {
                textView.insertionPointColor = .tertiaryLabelColor
            } else {
                textView.insertionPointColor = .labelColor
            }
        }
    }
}

/// NSScrollView subclass that reports intrinsic content height based on the text content,
/// so SwiftUI can auto-size the editor with `fixedSize(horizontal:vertical:)`.
/// Height is capped at `maxContentHeight` so the view scrolls instead of overflowing.
final class PromptEditorScrollView: NSScrollView {
    private var contentHeight: CGFloat = 80
    private let maxContentHeight: CGFloat

    init(maxHeight: CGFloat = 400) {
        self.maxContentHeight = maxHeight
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.maxContentHeight = 400
        super.init(coder: coder)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    func recalcIntrinsicHeight() {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
            + textView.textContainerInset.height * 2
        let newHeight = min(maxContentHeight, max(80, textHeight))
        if abs(newHeight - contentHeight) > 1 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}

/// NSTextView subclass that intercepts Return key for submit behavior.
final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onImagePaste: ((Data) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 // Return key
        let hasShift = event.modifierFlags.contains(.shift)

        if isReturn && !hasShift {
            // Enter without Shift → submit
            onSubmit()
            return
        }

        if isReturn && hasShift {
            // Shift+Enter → insert newline
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if tryPasteImage() { return }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Catch Cmd+V explicitly — in SwiftUI sheets the Edit menu may not dispatch paste: to us
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v" {
            if tryPasteImage() { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Try to extract an image from the clipboard. Returns true if an image was handled.
    private func tryPasteImage() -> Bool {
        guard let onImagePaste else { return false }
        let pb = NSPasteboard.general

        // Direct PNG data
        if let pngData = pb.data(forType: .png) {
            onImagePaste(pngData)
            return true
        }

        // TIFF data (screenshots, most image copies) → convert to PNG
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            onImagePaste(pngData)
            return true
        }

        // File URL pointing to an image
        if let urlData = pb.data(forType: .fileURL),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            onImagePaste(pngData)
            return true
        }

        return false
    }
}
