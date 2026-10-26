import AppKit
import Testing
@testable import KanbanCode

/// A conversation's composer sits over the Main chat's composer in the same
/// window. Cmd+V is offered to every view in the window, so an image pasted
/// with the conversation's composer focused must not land in Main's.
@Suite("Composer paste routing", .serialized)
@MainActor
struct ComposerPasteRoutingTests {
    @Test("Cmd+V puts an image only in the focused composer")
    func onlyTheFocusedComposerTakesTheImage() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        let main = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let conversation = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        // Main's composer comes first in the view tree, as it does under the
        // conversation's overlay.
        content.addSubview(main)
        content.addSubview(conversation)
        var pastedInto: [String] = []
        main.onImagePaste = { _ in pastedInto.append("main"); return "[Image #1]" }
        conversation.onImagePaste = { _ in pastedInto.append("conversation"); return "[Image #1]" }
        #expect(window.makeFirstResponder(conversation))

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        _ = content.performKeyEquivalent(with: event)

        #expect(pastedInto == ["conversation"])
        #expect(conversation.string.contains("[Image #1]"))
        #expect(main.string.isEmpty)
    }
}
