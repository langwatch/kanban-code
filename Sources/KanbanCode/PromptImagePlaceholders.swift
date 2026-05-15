import Foundation
import KanbanCodeCore

enum PromptImagePlaceholders {
    static func insertMarker<T>(for images: [T]) -> String {
        PromptImageLayout.marker(for: images.count + 1)
    }

    static func normalize<T>(text: String, images: [T]) -> (text: String, images: [T]) {
        guard !images.isEmpty, text.contains(PromptImageLayout.markerPrefix) else {
            return (text, images)
        }

        let parts = PromptImageLayout.parts(in: text, imageCount: images.count)
        guard parts.contains(where: { $0.imageIndex != nil }) else {
            return (text, [])
        }

        var normalizedText = ""
        var normalizedImages: [T] = []
        for part in parts {
            if let imageIndex = part.imageIndex {
                normalizedImages.append(images[imageIndex])
                normalizedText += PromptImageLayout.marker(for: normalizedImages.count)
            } else {
                normalizedText += part.text
            }
        }
        return (normalizedText, normalizedImages)
    }

    static func removeMarker<T>(displayIndex: Int, text: String, images: [T]) -> (text: String, images: [T]) {
        let marker = PromptImageLayout.marker(for: displayIndex)
        let updatedText = text.replacingOccurrences(of: marker, with: "")
        return normalize(text: updatedText, images: images)
    }
}
