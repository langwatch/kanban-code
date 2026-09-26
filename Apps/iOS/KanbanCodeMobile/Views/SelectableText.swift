import SwiftUI
import UIKit

/// Read-only text that selects like a text view: touch and hold, then drag
/// the handles over any part of it, with the system Copy and Look Up menu.
/// Links open on tap. SwiftUI's own text selection on iOS only copies the
/// whole text.
struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString
    /// false lays the text out on unwrapped lines, for code in a horizontal scroll view.
    var wraps = true
    var alignment: NSTextAlignment = .natural
    @Environment(\.selectableTextTap) private var onTap

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        // A tap on the text also reaches `selectableTextTap` (the chat puts
        // the keyboard away with it); the text view keeps its own taps.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = [.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        if !wraps {
            view.textContainer.widthTracksTextView = false
            view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            view.textContainer.lineBreakMode = .byClipping
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        if view.attributedText != text {
            view.attributedText = text
        }
        view.textAlignment = alignment
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?

        @objc func tapped() { onTap?() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        if wraps {
            let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
            let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
        }
        view.layoutManager.ensureLayout(for: view.textContainer)
        let used = view.layoutManager.usedRect(for: view.textContainer)
        return CGSize(width: ceil(used.width) + 1, height: ceil(used.height))
    }
}

/// Text for `SelectableText`: inline markdown (bold, italic, code, links)
/// as UIKit attributes, in the given style.
enum SelectableTextStyle {
    static func plain(_ text: String, font: UIFont = .preferredFont(forTextStyle: .body),
                      color: UIColor = .label) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    static func markdown(_ text: String, font: UIFont = .preferredFont(forTextStyle: .body),
                         color: UIColor = .label) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return plain(text, font: font, color: color)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                attributes[.backgroundColor] = UIColor.tertiarySystemFill
            }
            var traits = runFont.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

extension EnvironmentValues {
    /// Called on a plain tap on any `SelectableText` below.
    @Entry var selectableTextTap: (() -> Void)? = nil
}
