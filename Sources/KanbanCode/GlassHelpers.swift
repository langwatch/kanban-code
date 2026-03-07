import SwiftUI

extension View {
    /// Apply liquid glass effect to a column.
    /// Note: Actual glass effects require macOS 26+. Using fallback styling for macOS 15.
    func glassColumn() -> some View {
        // Fallback: subtle translucent background for macOS 15
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }

    /// Apply liquid glass effect to a search/modal overlay.
    /// Note: Actual glass effects require macOS 26+. Using fallback styling for macOS 15.
    func glassOverlay() -> some View {
        // Fallback: thicker material for overlays on macOS 15
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
    }

    /// Extend background under glass for visual continuity.
    /// Note: Background extension requires macOS 26+. No-op on macOS 15.
    func extendedBackground() -> some View {
        // No effect - return as-is
        self
    }
}
