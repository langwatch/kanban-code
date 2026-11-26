import SwiftUI
import UIKit

/// Puts the keyboard away on a tap anywhere in the window outside a text
/// input and outside the views marked with `keepsKeyboard(_:)` (the
/// composer and its buttons, the slash command list). The tap still goes
/// to what is under it, so buttons, rows and links keep working.
struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private var recognizer: UITapGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField { return false }
                if let text = current as? UITextView, text.isEditable { return false }
                view = current.superview
            }
            let point = touch.location(in: window)
            return !KeyboardKeepZones.contains(point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Frames, in window coordinates, where a tap keeps the keyboard up.
@MainActor
enum KeyboardKeepZones {
    private static var zones: [UUID: CGRect] = [:]

    static func set(_ id: UUID, _ frame: CGRect?) { zones[id] = frame }

    static func contains(_ point: CGPoint) -> Bool {
        zones.values.contains { $0.contains(point) }
    }
}

private struct KeepsKeyboard: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { KeyboardKeepZones.set(id, $0) }
            .onDisappear { KeyboardKeepZones.set(id, nil) }
    }
}

extension View {
    /// A tap on this view never puts the keyboard away.
    func keepsKeyboard() -> some View { modifier(KeepsKeyboard()) }
}
