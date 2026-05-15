import Foundation

/// Parses visible image placeholders embedded in prompt text.
///
/// The UI stores image position as plain text markers such as `[Image #1]`.
/// When sending to assistants that support image paste, those markers are
/// replaced by clipboard image paste events. Assistants without image paste
/// support receive markdown image references at the same positions.
public enum PromptImageLayout {
    public static let markerPrefix = "[Image #"

    public struct Part: Equatable, Sendable {
        public var text: String
        /// Zero-based image index, nil for text-only parts.
        public var imageIndex: Int?

        public init(text: String, imageIndex: Int? = nil) {
            self.text = text
            self.imageIndex = imageIndex
        }
    }

    public static func marker(for index: Int) -> String {
        "[Image #\(index)]"
    }

    public static func parts(in text: String, imageCount: Int) -> [Part] {
        guard imageCount > 0, text.contains(markerPrefix) else {
            return text.isEmpty ? [] : [Part(text: text)]
        }

        var parts: [Part] = []
        var cursor = text.startIndex
        while let markerStart = text.range(of: markerPrefix, range: cursor..<text.endIndex)?.lowerBound {
            guard let markerEnd = text[markerStart..<text.endIndex].firstIndex(of: "]") else {
                break
            }

            let numberStart = text.index(markerStart, offsetBy: markerPrefix.count)
            let numberText = String(text[numberStart..<markerEnd])
            guard let number = Int(numberText), number >= 1, number <= imageCount else {
                let markerAfterEnd = text.index(after: markerEnd)
                parts.append(Part(text: String(text[cursor..<markerAfterEnd])))
                cursor = markerAfterEnd
                continue
            }

            if markerStart > cursor {
                parts.append(Part(text: String(text[cursor..<markerStart])))
            }
            parts.append(Part(text: "", imageIndex: number - 1))
            cursor = text.index(after: markerEnd)
        }

        if cursor < text.endIndex {
            parts.append(Part(text: String(text[cursor..<text.endIndex])))
        }
        return coalescingAdjacentText(parts)
    }

    public static func referencedImageIndices(in text: String, imageCount: Int) -> [Int] {
        var out: [Int] = []
        for part in parts(in: text, imageCount: imageCount) {
            if let imageIndex = part.imageIndex {
                out.append(imageIndex)
            }
        }
        return out
    }

    public static func replacingMarkersWithMarkdown(in text: String, imagePaths: [String]) -> String {
        let parts = parts(in: text, imageCount: imagePaths.count)
        guard parts.contains(where: { $0.imageIndex != nil }) else {
            if imagePaths.isEmpty { return text }
            let refs = imagePaths.map { "![](\($0))" }.joined(separator: "\n")
            return text.isEmpty ? refs : text + "\n" + refs
        }

        return parts.map { part in
            if let imageIndex = part.imageIndex {
                return "![](\(imagePaths[imageIndex]))"
            }
            return part.text
        }.joined()
    }

    private static func coalescingAdjacentText(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        for part in parts {
            if part.imageIndex == nil,
               let last = out.last,
               last.imageIndex == nil {
                out[out.count - 1].text += part.text
            } else {
                out.append(part)
            }
        }
        return out
    }
}
