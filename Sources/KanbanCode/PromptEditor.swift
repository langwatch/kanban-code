import SwiftUI
import AppKit

/// A TextEditor replacement where Enter submits and Shift+Enter inserts a newline.
/// Reports its intrinsic height so SwiftUI can auto-size via `fixedSize(horizontal:vertical:)`.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var placeholder: String = ""
    var maxHeight: CGFloat = 400
    /// Identity tag — when this changes, the text view is force-updated regardless of focus.
    var identity: String = ""
    var onSubmit: () -> Void = {}
    var onCmdSubmit: (() -> Void)?
    var onUpArrowAtStart: (() -> String?)?
    var onDownArrowAtStart: (() -> String?)?
    /// Unconditional arrow hooks — fire on every up/down regardless of cursor
    /// position. If they return true, the key is consumed (no caret move, no
    /// history recall). Used to route arrows into the @-mention picker.
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onImagePaste: ((Data) -> Void)?
    var onEscape: (() -> Void)?

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
        textView.onCmdSubmit = onCmdSubmit
        textView.onUpArrowAtStart = onUpArrowAtStart
        textView.onDownArrowAtStart = onDownArrowAtStart
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onImagePaste = onImagePaste
        textView.onEscape = onEscape
        textView.placeholderString = placeholder

        // Disable macOS smart substitutions — prevents -- → em-dash, " → curly quotes, etc.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: PromptEditorScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        // CRITICAL: Update the coordinator's parent reference so textDidChange
        // writes to the CURRENT card's binding, not a stale one from makeCoordinator.
        context.coordinator.parent = self
        // Force update when the identity changes (e.g. switched to a different card).
        let identityChanged = context.coordinator.lastIdentity != identity
        if identityChanged {
            context.coordinator.lastIdentity = identity
        }
        // Only push text from binding when user is NOT actively editing,
        // OR when the identity changed (card switch — must show new card's draft).
        let isEditing = textView.window?.firstResponder === textView
        if textView.string != text && (!isEditing || text.isEmpty || identityChanged) {
            textView.string = text
            textView.needsDisplay = true // redraw placeholder if cleared
        }
        textView.onSubmit = onSubmit
        textView.onCmdSubmit = onCmdSubmit
        textView.onUpArrowAtStart = onUpArrowAtStart
        textView.onDownArrowAtStart = onDownArrowAtStart
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onImagePaste = onImagePaste
        textView.onEscape = onEscape
        textView.font = font

        // Update placeholder
        textView.placeholderString = placeholder
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(textView)
        textView.needsDisplay = true

        // Recalculate intrinsic height after text/font changes
        scrollView.recalcIntrinsicHeight()
    }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var placeholder: String = ""
        var lastIdentity: String = ""

        init(_ parent: PromptEditor) {
            self.parent = parent
            self.placeholder = parent.placeholder
            self.lastIdentity = parent.identity
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
        let newHeight = min(maxContentHeight, max(36, textHeight))
        if abs(newHeight - contentHeight) > 1 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}

/// NSTextView subclass that intercepts Return key for submit behavior.
final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onCmdSubmit: (() -> Void)?
    var onUpArrowAtStart: (() -> String?)?
    var onDownArrowAtStart: (() -> String?)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onImagePaste: ((Data) -> Void)?
    var onEscape: (() -> Void)?
    var placeholderString: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw placeholder when empty and not first responder (or always when empty)
        if string.isEmpty && !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ]
            let inset = textContainerInset
            let rect = NSRect(
                x: inset.width + 5,
                y: inset.height,
                width: bounds.width - inset.width * 2 - 10,
                height: bounds.height - inset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }

    override var needsDisplay: Bool {
        didSet { /* ensure redraw when text changes for placeholder */ }
    }

    override func keyDown(with event: NSEvent) {
        // Escape → stop assistant
        if event.keyCode == 53 {
            onEscape?()
            return
        }

        let isReturn = event.keyCode == 36 // Return key
        let hasShift = event.modifierFlags.contains(.shift)
        let hasCmd = event.modifierFlags.contains(.command)

        if isReturn && hasCmd && onCmdSubmit != nil {
            // Cmd+Enter → queue prompt (when handler is set)
            if let delegate = self.delegate as? PromptEditor.Coordinator {
                delegate.parent.text = self.string
            }
            onCmdSubmit?()
            return
        }

        if isReturn && !hasShift {
            // Enter → send
            if let delegate = self.delegate as? PromptEditor.Coordinator {
                delegate.parent.text = self.string
            }
            onSubmit()
            return
        }

        if isReturn && hasShift {
            // Shift+Enter → insert newline
            insertNewline(nil)
            return
        }

        // Up arrow — unconditional handler first (e.g. mention picker nav),
        // falls back to history recall at start-of-buffer.
        if event.keyCode == 126 { // up arrow
            if let handler = onArrowUp, handler() {
                return
            }
            let cursorAtStart = selectedRange().location == 0 && selectedRange().length == 0
            if (cursorAtStart || string.isEmpty), let handler = onUpArrowAtStart {
                if let replacement = handler() {
                    replaceTextAndCursorToStart(replacement)
                }
                return
            }
        }

        // Down arrow — same pattern.
        if event.keyCode == 125 { // down arrow
            if let handler = onArrowDown, handler() {
                return
            }
            let cursorAtStart = selectedRange().location == 0 && selectedRange().length == 0
            if (cursorAtStart || string.isEmpty), let handler = onDownArrowAtStart {
                if let replacement = handler() {
                    replaceTextAndCursorToStart(replacement)
                }
                return
            }
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

    /// Replace text, sync the binding, and move cursor to start.
    private func replaceTextAndCursorToStart(_ newText: String) {
        string = newText
        setSelectedRange(NSRange(location: 0, length: 0))
        if let delegate = self.delegate as? PromptEditor.Coordinator {
            delegate.parent.text = newText
        }
        (enclosingScrollView as? PromptEditorScrollView)?.recalcIntrinsicHeight()
        needsDisplay = true
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
