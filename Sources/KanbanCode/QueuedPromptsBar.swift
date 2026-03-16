import SwiftUI
import KanbanCodeCore

struct QueuedPromptsBar: View {
    let prompts: [QueuedPrompt]
    var onSendNow: (String) -> Void    // promptId
    var onEdit: (QueuedPrompt) -> Void
    var onRemove: (String) -> Void     // promptId
    var onReorder: (([String]) -> Void)?  // ordered promptIds

    @State private var draggingId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(prompts) { prompt in
                HStack(spacing: 6) {
                    if prompt.sendAutomatically {
                        Image(systemName: "bolt.fill")
                            .font(.app(size: 9))
                            .foregroundStyle(.orange)
                            .help("Will send automatically when Claude finishes")
                    }

                    Text(prompt.body)
                        .font(.app(.caption))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Send Now") {
                        onSendNow(prompt.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        onEdit(prompt)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.app(.caption2))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")

                    Button {
                        onRemove(prompt.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove prompt")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .opacity(draggingId == prompt.id ? 0.4 : 1)
                .onDrag {
                    draggingId = prompt.id
                    return NSItemProvider(object: prompt.id as NSString)
                }
                .onDrop(of: [.utf8PlainText], delegate: PromptReorderDelegate(
                    targetId: prompt.id,
                    prompts: prompts,
                    draggingId: $draggingId,
                    onReorder: onReorder
                ))

                if prompt.id != prompts.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.5))
    }
}

private struct PromptReorderDelegate: DropDelegate {
    let targetId: String
    let prompts: [QueuedPrompt]
    @Binding var draggingId: String?
    var onReorder: (([String]) -> Void)?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId, dragging != targetId else { return }
        var ids = prompts.map(\.id)
        guard let fromIndex = ids.firstIndex(of: dragging),
              let toIndex = ids.firstIndex(of: targetId) else { return }
        ids.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        onReorder?(ids)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
