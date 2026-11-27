import SwiftUI
import KanbanCodeCore

// MARK: - Remote mode copy

extension RemoteMode {
    /// Title of the mode in the Remote settings tab.
    var settingsTitle: String {
        switch self {
        case .ssh: "SSH machines"
        case .boxd: "boxd"
        case .mutagen: "Mutagen"
        }
    }

    /// One line on what the mode does.
    var settingsDescription: String {
        switch self {
        case .ssh:
            "Run cards on always-on machines you own, reached over ssh or Tailscale."
        case .boxd:
            "Each card gets its own boxd cloud machine, paused when idle. Needs a boxd account."
        case .mutagen:
            "Sync files with one ssh host. The assistant runs on this Mac and runs its commands on the host."
        }
    }
}

// MARK: - Boxd form

/// Form sections of the ssh and boxd remote modes, which share one
/// `BoxdSettings` block: the ssh mode shows the ssh machines, the boxd mode
/// the boxd machine and lifecycle, and both the project setup. Used inside
/// the `Form` of the Remote settings tab, so the body is a set of `Section`s.
struct BoxdSettingsView: View {
    let mode: RemoteMode

    @State private var snapshotName = BoxdSettings.defaultSnapshotName
    @State private var sourceMachine = BoxdSettings.defaultSourceMachine
    @State private var folderTemplate = BoxdSettings.defaultFolderTemplate
    @State private var initCommand = BoxdSettings.defaultInitCommand
    @State private var copyGlobsText = BoxdSettings.defaultCopyGlobs.joined(separator: "\n")
    @State private var inactivityMinutes = BoxdSettings.defaultInactivityTimeoutSeconds / 60
    /// Edited in the Assistants tab; carried through the save unchanged.
    @State private var claudeOAuthToken = ""
    @State private var sshMachines: [SshMachine] = []
    @State private var sshReachability: [String: Bool] = [:]

    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    @State private var boxdAvailable = true
    @State private var machines: [String] = []
    @State private var isSavingSnapshot = false
    @State private var snapshotMessage: String?
    @State private var snapshotFailed = false

    private let settingsStore = SettingsStore()

    /// Shortest timeout the settings accept, in minutes.
    private static let minimumMinutes = max(1, BoxdSettings.minimumInactivityTimeoutSeconds / 60)

    var body: some View {
        if mode == .ssh {
            sshSections
        } else {
            boxdSections
        }
        projectSection
            .task(id: mode) { await load() }
    }

    @ViewBuilder
    private var sshSections: some View {
        Section("Machines") {
            if !sshMachines.isEmpty {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 8, height: 1)
                    Text("Name").frame(width: 130, alignment: .leading)
                    Text("Ssh target").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Repositories").frame(width: 130, alignment: .leading)
                    Color.clear.frame(width: 16, height: 1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach($sshMachines) { $machine in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(reachabilityColor(machine))
                            .frame(width: 8, height: 8)
                            .help(reachabilityHelp(machine))
                        TextField("Name", text: $machine.name, prompt: Text("name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        TextField("Ssh target", text: $machine.target, prompt: Text("user@host"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        TextField("Repositories", text: $machine.repoRoot, prompt: Text(SshMachine.defaultRepoRoot))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 130)
                        Button {
                            sshMachines.removeAll { $0.id == machine.id }
                            scheduleSave()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    if let master = master(of: machine) {
                        Text("Runs Kanban Code (paired in Remote Control > Peers): cards started here are owned by its server and keep going while this Mac is off. \(master.masterOnline ? "Online." : "Offline.")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                }
            }
            .onChange(of: sshMachines) { scheduleSave() }

            HStack {
                Button("Add machine") {
                    sshMachines.append(SshMachine(name: "machine-\(sshMachines.count + 1)", target: ""))
                }
                .controlSize(.small)
                Button("Check") { Task { await probeSshMachines() } }
                    .controlSize(.small)
                    .disabled(sshMachines.isEmpty)
            }

            Text("Each machine needs tmux, git, node and the coding assistant, and rush to run cards on rush. Repositories are cloned into the folder on the right. Cards share the machine, the app never stops it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }


        Section("Masters") {
            Text("A machine that also runs kanban-code-server can own cards itself and keep them going while this Mac sleeps. Pair it in Settings > Remote Control > Peers.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var boxdSections: some View {
        if !boxdAvailable {
            Section("Dependency") {
                HStack {
                    Label("boxd", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("https://boxd.sh")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Install the boxd CLI and log in: https://boxd.sh")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        Section("Machine") {
            HStack {
                TextField("Snapshot", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: snapshotName) { scheduleSave() }
                if isSavingSnapshot {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Create snapshot now") { createSnapshot() }
                    .controlSize(.small)
                    .disabled(isSavingSnapshot || trimmedSnapshotName.isEmpty || trimmedSourceMachine.isEmpty)
            }

            if let snapshotMessage {
                Text(snapshotMessage)
                    .font(.caption)
                    .foregroundStyle(snapshotFailed ? Color.red : Color.green)
                    .textSelection(.enabled)
            }

            Text("Every machine is created from this snapshot.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if machines.isEmpty {
                TextField("Source machine", text: $sourceMachine)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: sourceMachine) { scheduleSave() }
            } else {
                Picker("Source machine", selection: $sourceMachine) {
                    ForEach(machineOptions, id: \.self) { machine in
                        Text(machine).tag(machine)
                    }
                }
                .onChange(of: sourceMachine) { scheduleSave() }
            }

            Text("The snapshot is saved from this machine.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        Section("Lifecycle") {
            HStack {
                Text("Pause after inactivity")
                Spacer()
                TextField("", value: $inactivityMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("minutes")
                    .foregroundStyle(.secondary)
                Stepper("", value: $inactivityMinutes, in: Self.minimumMinutes...1440)
                    .labelsHidden()
            }
            .onChange(of: inactivityMinutes) { scheduleSave() }

            Text("The machine is paused when the session shows no activity for this long.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var projectSection: some View {
        Section("Project") {
            if mode == .boxd {
                TextField("Project folder", text: $folderTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: folderTemplate) { scheduleSave() }
                Text("`${repo_name}` is the GitHub repository name of the project.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Initialization command")
                TextEditor(text: $initCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                    .onChange(of: initCommand) { scheduleSave() }
                Text("Runs on the machine before each session. Variables: `${repo_dir}`, `${repo_url}`, `${repo_name}`, `${branch}`.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Files to copy")
                TextEditor(text: $copyGlobsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
                    .onChange(of: copyGlobsText) { scheduleSave() }
                Text("Copied from the local project into the machine after the initialization command. One glob per line.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Derived values

    private var trimmedSnapshotName: String {
        snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSourceMachine: String {
        sourceMachine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Machine names of the picker. The saved machine stays in the list even
    /// when the CLI does not report it any more.
    private var machineOptions: [String] {
        var options = machines
        let current = trimmedSourceMachine
        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    // MARK: - Loading and saving

    private func load() async {
        let settings = try? await settingsStore.read()
        let boxd = settings?.boxd ?? BoxdSettings()
        snapshotName = boxd.snapshotName
        sourceMachine = boxd.sourceMachine
        folderTemplate = boxd.folderTemplate
        initCommand = boxd.initCommand
        copyGlobsText = boxd.copyGlobs.joined(separator: "\n")
        inactivityMinutes = max(Self.minimumMinutes, boxd.inactivityTimeoutSeconds / 60)
        claudeOAuthToken = boxd.claudeOAuthToken
        sshMachines = boxd.sshMachines
        loaded = true
        Task { await probeSshMachines() }

        guard mode == .boxd else { return }
        let adapter = BoxdCliAdapter()
        boxdAvailable = await adapter.isAvailable()
        if boxdAvailable {
            machines = ((try? await adapter.listMachines()) ?? [])
                .map(\.name)
                .filter { !$0.isEmpty }
                .sorted()
        }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        let boxd = currentSettings()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard var settings = try? await settingsStore.read() else { return }
            settings.boxd = boxd
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func currentSettings() -> BoxdSettings {
        BoxdSettings(
            snapshotName: trimmedSnapshotName,
            sourceMachine: trimmedSourceMachine,
            folderTemplate: folderTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            initCommand: initCommand,
            copyGlobs: copyGlobsText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            inactivityTimeoutSeconds: max(Self.minimumMinutes, inactivityMinutes) * 60,
            claudeOAuthToken: claudeOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines),
            sshMachines: sshMachines.map {
                SshMachine(
                    id: $0.id,
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    target: $0.target.trimmingCharacters(in: .whitespacesAndNewlines),
                    repoRoot: $0.repoRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? SshMachine.defaultRepoRoot : $0.repoRoot.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
    }

    // MARK: - Ssh machines

    private func probeSshMachines() async {
        for machine in sshMachines where machine.isComplete {
            sshReachability[machine.name] = nil
        }
        await withTaskGroup(of: (String, Bool).self) { group in
            for machine in sshMachines where machine.isComplete {
                group.addTask { (machine.name, await SshHostPort.isReachable(target: machine.target)) }
            }
            for await (name, reachable) in group {
                sshReachability[name] = reachable
            }
        }
    }

    /// The machine's entry when it runs a paired master.
    private func master(of machine: SshMachine) -> MachineChoice? {
        AppComposition.shared.store.state.machineChoices.first { $0.sshMachine == machine && $0.master != nil }
    }

    private func reachabilityColor(_ machine: SshMachine) -> Color {
        if let master = master(of: machine) { return master.masterOnline ? .green : .red }
        return switch sshReachability[machine.name] {
        case .some(true): .green
        case .some(false): .red
        case .none: .secondary
        }
    }

    private func reachabilityHelp(_ machine: SshMachine) -> String {
        if let master = master(of: machine) {
            return master.masterOnline ? "Its Kanban Code server answers" : "Its Kanban Code server does not answer"
        }
        return switch sshReachability[machine.name] {
        case .some(true): "\(machine.target) answers over ssh"
        case .some(false): "\(machine.target) does not answer over ssh"
        case .none: "Not checked"
        }
    }

    // MARK: - Snapshot

    private func createSnapshot() {
        let machine = trimmedSourceMachine
        let name = trimmedSnapshotName
        isSavingSnapshot = true
        snapshotMessage = nil
        snapshotFailed = false
        Task {
            do {
                try await BoxdCliAdapter().saveSnapshot(machine: machine, name: name)
                snapshotMessage = "Snapshot \(name) saved"
                snapshotFailed = false
            } catch {
                snapshotMessage = error.localizedDescription
                snapshotFailed = true
            }
            isSavingSnapshot = false
        }
    }
}
