import SwiftUI
import KanbanCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var onCreate: (String, String, String?) -> Void = { _, _, _ in }

    @State private var title = ""
    @State private var description = ""
    @State private var projectPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("Description (optional)", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            TextField("Project path (optional)", text: $projectPath)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    let proj = projectPath.isEmpty ? nil : projectPath
                    onCreate(title, description, proj)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
