import SwiftUI
import KanbanCodeRemoteKit

struct NewTaskSheet: View {
    let board: BoardModel
    let onCreated: (RemoteCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("newTask.lastProject") private var lastProject = ""
    @State private var projectPath = ""
    @State private var prompt = ""
    @State private var useWorktree = false
    @State private var worktreeName = ""
    @State private var isLaunching = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    private var projects: [RemoteProject] { board.board?.projects ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if projects.isEmpty {
                        Text("The Mac has no projects yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $projectPath) {
                            ForEach(projects) { project in
                                Text(project.name).tag(project.path)
                            }
                        }
                        .accessibilityIdentifier("projectPicker")
                    }
                }

                Section("Prompt") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($promptFocused)
                        .accessibilityIdentifier("taskPrompt")
                }

                Section {
                    Toggle("Own worktree", isOn: $useWorktree.animation())
                        .accessibilityIdentifier("worktreeToggle")
                    if useWorktree {
                        TextField("Name (random if empty)", text: $worktreeName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("A worktree gives the task its own branch and checkout.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLaunching {
                        ProgressView()
                    } else {
                        Button("Launch") { launch() }
                            .fontWeight(.semibold)
                            .disabled(!canLaunch)
                            .accessibilityIdentifier("launchTask")
                    }
                }
            }
            .onAppear {
                if projectPath.isEmpty {
                    projectPath = projects.contains { $0.path == lastProject } ? lastProject : (projects.first?.path ?? "")
                }
                promptFocused = true
            }
        }
        .presentationDetents([.large])
    }

    private var canLaunch: Bool {
        !projectPath.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launch() {
        guard let client = board.client, canLaunch else { return }
        isLaunching = true
        error = nil
        let request = RemoteTaskRequest(
            project: projectPath,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            worktree: useWorktree ? worktreeName.trimmingCharacters(in: .whitespaces) : nil
        )
        Task {
            defer { isLaunching = false }
            do {
                let card = try await client.createTask(request)
                lastProject = projectPath
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                onCreated(card)
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

#Preview {
    NewTaskSheet(board: BoardModel(preview: PreviewData.board)) { _ in }
}
