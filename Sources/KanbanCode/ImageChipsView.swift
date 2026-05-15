import SwiftUI
import KanbanCodeCore

/// Shared "Prompt" section: label, image chips (above editor, like Claude Code), and the editor.
struct PromptSection: View {
    @Binding var text: String
    @Binding var images: [ImageAttachment]
    var placeholder: String = "Describe what you want Claude to do..."
    var minHeight: CGFloat = 80
    var maxHeight: CGFloat = 400
    var onSubmit: () -> Void = {}
    @State private var usesInlineImageMarkers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.app(.caption))
                .foregroundStyle(.secondary)

            ImageChipsView(images: $images) { displayIndex in
                let normalized = PromptImagePlaceholders.removeMarker(
                    displayIndex: displayIndex,
                    text: text,
                    images: images
                )
                text = normalized.text
                images = normalized.images
            }

            PromptEditor(
                text: $text,
                placeholder: placeholder,
                maxHeight: maxHeight,
                onSubmit: onSubmit,
                onImagePaste: { data in
                    usesInlineImageMarkers = true
                    let marker = PromptImagePlaceholders.insertMarker(for: images)
                    images.append(ImageAttachment(data: data))
                    return marker
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: minHeight, maxHeight: maxHeight, alignment: .top)
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            usesInlineImageMarkers = text.contains(PromptImageLayout.markerPrefix)
        }
        .onChange(of: text) { _, newValue in
            guard usesInlineImageMarkers else { return }
            if !newValue.contains(PromptImageLayout.markerPrefix) {
                images = []
                return
            }
            let normalized = PromptImagePlaceholders.normalize(text: newValue, images: images)
            if normalized.text != newValue {
                text = normalized.text
            }
            if normalized.images.count != images.count {
                images = normalized.images
            }
        }
    }
}

/// Horizontal strip of image attachment chips with remove buttons and hover previews.
struct ImageChipsView: View {
    @Binding var images: [ImageAttachment]
    var onRemove: ((Int) -> Void)?

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        ImageChip(index: index + 1, imageData: image.data) {
                            if let onRemove {
                                onRemove(index + 1)
                            } else {
                                images.removeAll { $0.id == image.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 0)
            }
            .frame(height: 28)
        }
    }
}

private struct ImageChip: View {
    let index: Int
    let imageData: Data
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.caption2)
            Text("Image #\(index)")
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .popover(isPresented: $isHovering) {
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 300)
                    .padding(4)
            }
        }
    }
}
