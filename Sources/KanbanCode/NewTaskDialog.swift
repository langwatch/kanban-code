import SwiftUI
import KanbanCodeCore

struct NewTaskDialog: View {
    @Binding var isPresented: Bool
    var projects: [Project] = []
    var defaultProjectPath: String?
    var globalRemoteSettings: RemoteSettings?
    /// (prompt, projectPath, title, startImmediately, images) — creates task, optionally starts via LaunchConfirmation
    var onCreate: (String, String?, String?, Bool, [ImageAttachment]) -> Void = { _, _, _, _, _ in }
    /// (prompt, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride, images) — creates and launches directly (skips LaunchConfirmation)
    var onCreateAndLaunch: (String, String?, String?, Bool, Bool, Bool, String?, [ImageAttachment]) -> Void = { _, _, _, _, _, _, _, _ in }

    @State private var prompt = ""
    @State private var images: [ImageAttachment] = []
    @State private var title = ""
    @State private var selectedProjectPath: String = ""
    @State private var customPath = ""
    @State private var command = ""
    @State private var commandEdited = false
    @AppStorage("startTaskImmediately") private var startImmediately = true
    @AppStorage("createWorktree") private var createWorktree = true
    @State private var runRemotely = true
    @AppStorage("dangerouslySkipPermissions") private var dangerouslySkipPermissions = true
    @AppStorage("lastSelectedProjectPath") private var lastSelectedProjectPath = ""

    private static let customPathSentinel = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.app(.title3))
                .fontWeight(.semibold)

            // Prompt
            PromptSection(
                text: $prompt,
                images: $images,
                placeholder: "Describe what you want Claude to do...",
                onSubmit: submitForm
            )

            // Title (optional)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.app(.callout))

            // Project picker
            if projects.isEmpty {
                TextField("Project path (optional)", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.caption))
            } else {
                Picker("Project", selection: $selectedProjectPath) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.path)
                    }
                    Divider()
                    Text("Custom path...").tag(Self.customPathSentinel)
                }

                if selectedProjectPath == Self.customPathSentinel {
                    TextField("Project path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.caption))
                }
            }

            // Start immediately toggle
            Toggle("Start immediately", isOn: $startImmediately)
                .font(.app(.callout))

            // Launch options (shown when "Start immediately" is checked)
            if startImmediately {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Create worktree", isOn: isGitRepo ? $createWorktree : .constant(false))
                        .font(.app(.callout))
                        .disabled(!isGitRepo)
                    if !isGitRepo {
                        Label("Not a git repository", systemImage: "info.circle")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    Toggle("Run remotely", isOn: hasRemoteConfig ? $runRemotely : .constant(false))
                        .font(.app(.callout))
                        .disabled(!hasRemoteConfig)
                    if !hasRemoteConfig {
                        Label(
                            globalRemoteSettings != nil
                                ? "Project not under remote sync path"
                                : "Configure remote execution in Settings > Remote",
                            systemImage: "info.circle"
                        )
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    Toggle("Dangerously skip permissions", isOn: $dangerouslySkipPermissions)
                        .font(.app(.callout))
                }

                // Editable command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $command)
                        .font(.app(.caption).monospaced())
                        .frame(minHeight: 36, maxHeight: 80)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: command) {
                            if command != commandPreview {
                                commandEdited = true
                            }
                        }
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(startImmediately ? "Create & Start" : "Create", action: submitForm)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear {
            if !lastSelectedProjectPath.isEmpty,
               projects.contains(where: { $0.path == lastSelectedProjectPath }) {
                selectedProjectPath = lastSelectedProjectPath
            } else if let defaultPath = defaultProjectPath,
               projects.contains(where: { $0.path == defaultPath }) {
                selectedProjectPath = defaultPath
            } else if let first = projects.first {
                selectedProjectPath = first.path
            }
            if let path = resolvedProjectPath {
                runRemotely = UserDefaults.standard.object(forKey: "runRemotely_\(path)") as? Bool ?? true
            }
            command = commandPreview
        }
        .onChange(of: prompt) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: createWorktree) {
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: runRemotely) {
            if let path = resolvedProjectPath {
                UserDefaults.standard.set(runRemotely, forKey: "runRemotely_\(path)")
            }
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: selectedProjectPath) {
            if let path = resolvedProjectPath {
                runRemotely = UserDefaults.standard.object(forKey: "runRemotely_\(path)") as? Bool ?? true
            }
            if !commandEdited { command = commandPreview }
        }
        .onChange(of: dangerouslySkipPermissions) {
            if !commandEdited { command = commandPreview }
        }
    }

    // MARK: - Actions

    private func submitForm() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let proj = resolvedProjectPath
        let titleOrNil = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let proj { lastSelectedProjectPath = proj }
        if startImmediately {
            onCreateAndLaunch(
                prompt,
                proj,
                titleOrNil,
                createWorktree && isGitRepo,
                runRemotely && hasRemoteConfig,
                dangerouslySkipPermissions,
                commandEdited ? command : nil,
                images
            )
        } else {
            onCreate(prompt, proj, titleOrNil, false, images)
        }
        isPresented = false
    }

    // MARK: - Computed

    private var resolvedProjectPath: String? {
        if projects.isEmpty {
            return customPath.isEmpty ? nil : customPath
        }
        if selectedProjectPath == Self.customPathSentinel {
            return customPath.isEmpty ? nil : customPath
        }
        return selectedProjectPath.isEmpty ? nil : selectedProjectPath
    }

    private var selectedProject: Project? {
        projects.first(where: { $0.path == resolvedProjectPath })
    }

    private var isGitRepo: Bool {
        guard let path = resolvedProjectPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private var hasRemoteConfig: Bool {
        guard let remote = globalRemoteSettings else { return false }
        guard let path = resolvedProjectPath else { return false }
        return path.hasPrefix(remote.localPath)
    }

    private var remoteHost: String? {
        globalRemoteSettings?.host
    }

    private var commandPreview: String {
        var parts: [String] = []

        if runRemotely && hasRemoteConfig {
            parts.append("SHELL=~/.kanban-code/remote/zsh")
        }

        var cmd = "claude"
        if dangerouslySkipPermissions { cmd += " --dangerously-skip-permissions" }

        if createWorktree && isGitRepo {
            cmd += " --worktree"
        }

        parts.append(cmd)

        return parts.joined(separator: " \\\n  ")
    }
}
