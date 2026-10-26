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
    /// Enter-key pre-submit hook. If this returns a non-nil string, the text
    /// view is directly replaced with that string (bypassing the binding
    /// update-guard that blocks async state pushes while typing), and
    /// `onSubmit` is NOT called. Used for @-mention autocomplete — typing
    /// `@ali<Enter>` must visibly expand to `@alice ` in the editor.
    var onEnterIntercept: (() -> String?)?
    /// Tab-key intercept. Used by @-mention autocomplete so Tab accepts the
    /// selected suggestion instead of moving focus away from the composer.
    var onTabIntercept: (() -> String?)?
    var onImagePaste: ((Data) -> String?)?
    var onEscape: (() -> Void)?
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Bump this to take the keyboard, with the caret after the last character
    /// and that end of the draft in view. Focus alone leaves a long draft
    /// showing its first line with the caret somewhere below the fold.
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PromptEditorScrollView {
        let scrollView = PromptEditorScrollView(maxHeight: maxHeight)
        scrollView.onHeightChange = onHeightChange
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
        textView.onEnterIntercept = onEnterIntercept
        textView.onTabIntercept = onTabIntercept
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

    static func dismantleNSView(_ scrollView: PromptEditorScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? SubmitTextView {
            textView.prepareForDismantle()
        }
        scrollView.documentView = nil
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
        // OR when the identity changed (card switch — must show new card's draft),
        // OR when there is nothing on screen to overwrite. That last case is a
        // draft restored from disk: the load is async, so it lands after the
        // composer has already mounted empty and taken focus, and without it
        // the draft stays invisible until the first keystroke replaces it.
        let isEditing = textView.window?.firstResponder === textView
        let wasEmpty = textView.string.isEmpty
        if textView.string != text && (!isEditing || text.isEmpty || identityChanged || wasEmpty) {
            textView.string = text
            textView.needsDisplay = true // redraw placeholder if cleared
            if !text.isEmpty && (identityChanged || wasEmpty) {
                textView.moveCaretToEnd()
            }
        }
        if identityChanged {
            textView.clearUndoStack()
        }
        textView.onSubmit = onSubmit
        textView.onCmdSubmit = onCmdSubmit
        textView.onUpArrowAtStart = onUpArrowAtStart
        textView.onDownArrowAtStart = onDownArrowAtStart
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onEnterIntercept = onEnterIntercept
        textView.onTabIntercept = onTabIntercept
        textView.onImagePaste = onImagePaste
        textView.onEscape = onEscape
        textView.font = font

        // Update placeholder
        textView.placeholderString = placeholder
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(textView)
        textView.needsDisplay = true

        // Recalculate intrinsic height after text/font changes
        scrollView.onHeightChange = onHeightChange
        scrollView.recalcIntrinsicHeight()
        scrollView.scheduleRecalcIntrinsicHeight()

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // A turn later: on the pass that mounts the view there is no window
            // to make it first responder in, and the height it just asked for
            // has not been applied, so scrolling to the caret would measure
            // against the old one.
            DispatchQueue.main.async { textView.focusAtEnd() }
        }
    }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var placeholder: String = ""
        var lastIdentity: String = ""
        var lastFocusToken: Int

        init(_ parent: PromptEditor) {
            self.parent = parent
            self.placeholder = parent.placeholder
            self.lastIdentity = parent.identity
            self.lastFocusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder(textView)
            // Recalculate height when user types
            if let scrollView = textView.enclosingScrollView as? PromptEditorScrollView {
                scrollView.recalcIntrinsicHeight()
                scrollView.scheduleRecalcIntrinsicHeight()
            }
            textView.scrollRangeToVisible(textView.selectedRange())
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
    private var lastMeasuredWidth: CGFloat = 320
    private var pendingRecalc = false
    private let maxContentHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void = { _ in }

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

        let measuredWidth = [
            contentView.documentVisibleRect.width,
            contentView.bounds.width,
            bounds.width,
            superview?.bounds.width ?? 0,
        ].first { $0 > 8 }
        if let measuredWidth {
            lastMeasuredWidth = measuredWidth
        }

        let contentWidth = max(1, lastMeasuredWidth)
        let textInsets = textView.textContainerInset.width * 2
        textContainer.containerSize = NSSize(
            width: max(1, contentWidth - textInsets),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame.size.width = contentWidth

        textView.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
            + textView.textContainerInset.height * 2
        let newHeight = min(maxContentHeight, max(36, textHeight))
        textView.frame.size.height = max(newHeight, textHeight)
        hasVerticalScroller = textHeight > maxContentHeight
        if abs(newHeight - contentHeight) > 1 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
            superview?.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onHeightChange(self.contentHeight)
            }
        }
    }

    func scheduleRecalcIntrinsicHeight() {
        guard !pendingRecalc else { return }
        pendingRecalc = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRecalc = false
            self.recalcIntrinsicHeight()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalcIntrinsicHeight()
    }

    override func layout() {
        super.layout()
        recalcIntrinsicHeight()
    }
}

/// NSTextView subclass that intercepts Return key for submit behavior.
final class SubmitTextView: NSTextView {
    private let localUndoManager = UndoManager()
    var onSubmit: () -> Void = {}
    var onCmdSubmit: (() -> Void)?
    var onUpArrowAtStart: (() -> String?)?
    var onDownArrowAtStart: (() -> String?)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onEnterIntercept: (() -> String?)?
    var onTabIntercept: (() -> String?)?
    var onImagePaste: ((Data) -> String?)?
    var onEscape: (() -> Void)?
    var placeholderString: String = ""

    override var undoManager: UndoManager? { localUndoManager }

    func clearUndoStack() {
        localUndoManager.removeAllActions()
    }

    /// Puts the caret after the last character and brings it into view.
    func moveCaretToEnd() {
        let end = (string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Takes the keyboard and picks up where typing left off.
    func focusAtEnd() {
        window?.makeFirstResponder(self)
        moveCaretToEnd()
    }

    func prepareForDismantle() {
        clearUndoStack()
        delegate = nil
        onSubmit = {}
        onCmdSubmit = nil
        onUpArrowAtStart = nil
        onDownArrowAtStart = nil
        onArrowUp = nil
        onArrowDown = nil
        onEnterIntercept = nil
        onTabIntercept = nil
        onImagePaste = nil
        onEscape = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            prepareForDismantle()
        }
        super.viewWillMove(toWindow: newWindow)
    }

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
        let isTab = event.keyCode == 48
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
            // Enter-key pre-submit intercept (e.g. @-mention autocomplete).
            // The handler returns a replacement string if it wants to swallow
            // Enter. Apply it directly to the NSTextView — bypasses the
            // updateNSView guard that blocks binding-driven text pushes while
            // the editor is first responder.
            if let handler = onEnterIntercept, let replacement = handler() {
                string = replacement
                setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
                if let delegate = self.delegate as? PromptEditor.Coordinator {
                    delegate.parent.text = replacement
                }
                refreshEditorHeightAfterProgrammaticChange()
                needsDisplay = true
                return
            }
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

        if isTab {
            if let handler = onTabIntercept, let replacement = handler() {
                replaceTextAndCursorToEnd(replacement)
                return
            }
            super.keyDown(with: event)
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
        refreshEditorHeightAfterProgrammaticChange()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Catch Cmd+V explicitly: in SwiftUI sheets the Edit menu may not dispatch paste: to us.
        // AppKit offers key equivalents to every view in the window, so only
        // the focused editor takes it; a hidden composer under another one
        // would take the images otherwise.
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
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
        refreshEditorHeightAfterProgrammaticChange()
        needsDisplay = true
    }

    private func replaceTextAndCursorToEnd(_ newText: String) {
        string = newText
        setSelectedRange(NSRange(location: (newText as NSString).length, length: 0))
        if let delegate = self.delegate as? PromptEditor.Coordinator {
            delegate.parent.text = newText
        }
        refreshEditorHeightAfterProgrammaticChange()
        needsDisplay = true
    }

    private func refreshEditorHeightAfterProgrammaticChange() {
        guard let scrollView = enclosingScrollView as? PromptEditorScrollView else { return }
        scrollView.recalcIntrinsicHeight()
        scrollView.scheduleRecalcIntrinsicHeight()
    }

    /// Try to extract an image from the clipboard. Returns true if an image was handled.
    private func tryPasteImage() -> Bool {
        guard let onImagePaste else { return false }
        let pb = NSPasteboard.general

        // Direct PNG data
        if let pngData = pb.data(forType: .png) {
            insertImagePlaceholder(onImagePaste(pngData))
            return true
        }

        // TIFF data (screenshots, most image copies) → convert to PNG
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            insertImagePlaceholder(onImagePaste(pngData))
            return true
        }

        // File URL pointing to an image
        if let urlData = pb.data(forType: .fileURL),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let image = NSImage(contentsOf: url),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            insertImagePlaceholder(onImagePaste(pngData))
            return true
        }

        return false
    }

    private func insertImagePlaceholder(_ placeholder: String?) {
        guard let placeholder, !placeholder.isEmpty else { return }
        insertText(placeholder, replacementRange: selectedRange())
        if let delegate = self.delegate as? PromptEditor.Coordinator {
            delegate.parent.text = string
        }
        refreshEditorHeightAfterProgrammaticChange()
        needsDisplay = true
    }
}
