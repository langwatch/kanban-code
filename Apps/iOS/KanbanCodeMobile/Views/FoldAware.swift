import SwiftUI

/// Where the display folds, in the coordinate space of the view that asked.
/// Only a half-open iPhone Duo reports one: flat open, the hinge is not in the
/// way and content may cross it; closed, only the cover display is in use.
nonisolated struct Fold: Equatable, Sendable {
    var frame: CGRect
    var isVertical: Bool { frame.height > frame.width }
}

extension GeometryProxy {
    /// The active fold, through `reservedRegions(kind: .division)` on the
    /// iOS 27.1 SDK and later. Builds made with an older SDK never see one.
    nonisolated var fold: Fold? {
        #if compiler(>=6.3)
        if #available(iOS 27.1, *) {
            let frame = reservedRegions(kind: .division).first(where: \.isActive)?.frame
            return frame.flatMap { $0.isEmpty ? nil : Fold(frame: $0) }
        }
        #endif
        return nil
    }
}

extension View {
    /// Keeps this view's content off the fold: the side of the view the fold
    /// crosses is inset to the fold's far edge, so text, buttons and the
    /// composer sit on one half. A horizontal fold (the phone held like a
    /// laptop) keeps the content on the top half.
    func avoidingFold() -> some View { modifier(FoldInset()) }

    /// Reports the fold in this view's coordinate space.
    func onFoldChange(_ action: @escaping (Fold?) -> Void) -> some View {
        onGeometryChange(for: Fold?.self, of: { $0.fold }, action: action)
    }
}

private struct FoldInset: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(insets)
            .onGeometryChange(for: EdgeInsets.self, of: { Self.insets(for: $0.fold, in: $0.size) }) { insets = $0 }
    }

    nonisolated static func insets(for fold: Fold?, in size: CGSize) -> EdgeInsets {
        guard let fold else { return EdgeInsets() }
        let f = fold.frame
        if fold.isVertical {
            guard f.maxX > 0, f.minX < size.width else { return EdgeInsets() }
            // The view lives on the side that holds most of it.
            return f.midX < size.width / 2
                ? EdgeInsets(top: 0, leading: max(0, f.maxX), bottom: 0, trailing: 0)
                : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: max(0, size.width - f.minX))
        }
        guard f.maxY > 0, f.minY < size.height else { return EdgeInsets() }
        return EdgeInsets(top: 0, leading: 0, bottom: max(0, size.height - f.minY), trailing: 0)
    }
}
