import SwiftUI

extension View {
    /// Apply liquid glass effect to a column.
    /// Uses Liquid Glass on macOS 26+, falls back to translucent material on macOS 15.
    @ViewBuilder
    func glassColumn() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        }
    }

    /// Apply liquid glass effect to a search/modal overlay.
    /// Uses Liquid Glass on macOS 26+, falls back to regular material on macOS 15.
    @ViewBuilder
    func glassOverlay() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        }
    }

    /// Apply liquid glass capsule effect to a button or small element.
    /// Uses Liquid Glass on macOS 26+, no-op on macOS 15.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
        }
    }

    /// Extend background under glass for visual continuity.
    /// Uses backgroundExtensionEffect on macOS 26+, no-op on macOS 15.
    @ViewBuilder
    func extendedBackground() -> some View {
        self
    }
}
