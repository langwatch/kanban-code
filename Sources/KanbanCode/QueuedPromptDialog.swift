import SwiftUI
import KanbanCodeCore

struct QueuedPromptDialog: View {
    @Binding var isPresented: Bool
    var existingPrompt: QueuedPrompt?
    var assistant: CodingAssistant = .claude
    var onSave: (String, Bool, [ImageAttachment]) -> Void // (body, sendAutomatically, images)

    @AppStorage("queuedPromptSendAutomatically") private var lastSendAutomatically: Bool = true
    @State private var promptText: String
    @State private var sendAutomatically: Bool
    @State private var images: [ImageAttachment]

    init(
        isPresented: Binding<Bool>,
        existingPrompt: QueuedPrompt? = nil,
        existingImages: [ImageAttachment] = [],
        assistant: CodingAssistant = .claude,
        onSave: @escaping (String, Bool, [ImageAttachment]) -> Void
    ) {
        self._isPresented = isPresented
        self.existingPrompt = existingPrompt
        self.assistant = assistant
        self.onSave = onSave
        self._promptText = State(initialValue: existingPrompt?.body ?? "")
        let defaultAuto = UserDefaults.standard.object(forKey: "queuedPromptSendAutomatically") as? Bool ?? true
        self._sendAutomatically = State(initialValue: existingPrompt?.sendAutomatically ?? defaultAuto)
        // Use passed-in images first, fall back to loading from prompt's temp paths
        if !existingImages.isEmpty {
            self._images = State(initialValue: existingImages)
        } else {
            let loaded: [ImageAttachment] = (existingPrompt?.imagePaths ?? []).compactMap { ImageAttachment.fromPath($0) }
            self._images = State(initialValue: loaded)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingPrompt != nil ? "Edit Queued Prompt" : "Queue Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            PromptSection(
                text: $promptText,
                images: $images,
                placeholder: "Type the next prompt for \(assistant.displayName)...",
                maxHeight: 300,
                onSubmit: submit
            )

            Toggle("Send automatically when \(assistant.displayName) finishes", isOn: $sendAutomatically)
                .font(.app(.callout))

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(existingPrompt != nil ? "Save" : "Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    private func submit() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSendAutomatically = sendAutomatically
        onSave(trimmed, sendAutomatically, images)
        isPresented = false
    }
}
