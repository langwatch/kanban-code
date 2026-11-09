import SwiftUI
import KanbanCodeCore

/// Settings > Claude Accounts: Claude Code config folders besides
/// `~/.claude` (`CLAUDE_CONFIG_DIR`), the projects that use each, and the
/// GitHub login `gh` uses for them.
struct ClaudeAccountsSettingsView: View {
    private let settingsStore = SettingsStore()
    @State private var accounts: [ClaudeAccount] = []
    /// The row whose login the machines get, nil for the default. A row,
    /// not a folder, so it follows its folder being retyped.
    @State private var loginRow: Int?
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var hooksInstalled: [String: Bool] = [:]
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                Text("Sessions in `~/.claude` always show. Add a folder you run Claude Code with as `CLAUDE_CONFIG_DIR` (for instance from direnv) to see its sessions too. New cards in an account's project folders start with its folder, and a resumed card runs with the folder its conversation is in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let loadError {
                    Label("Settings could not be read, so nothing is saved: \(loadError)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            ForEach(accounts.indices, id: \.self) { index in
                if accounts.indices.contains(index) {
                Section {
                    accountRows(index)
                } header: {
                    HStack {
                        Text(accounts[index].name.isEmpty ? "Account" : accounts[index].name)
                        Spacer()
                        Button(role: .destructive) {
                            guard accounts.indices.contains(index) else { return }
                            if let row = loginRow {
                                loginRow = row == index ? nil : (row > index ? row - 1 : row)
                            }
                            accounts.remove(at: index)
                            scheduleSave()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this account")
                    }
                }
                }
            }

            Section {
                Button {
                    accounts.append(ClaudeAccount(name: "", configDirectory: "~/.claude-"))
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }

            Section("Remote Machines") {
                Picker("Login for machines", selection: $loginRow) {
                    Text("Default (~/.claude)").tag(Int?.none)
                    ForEach(accounts.indices, id: \.self) { index in
                        if accounts.indices.contains(index), !accounts[index].configDirectory.isEmpty {
                            Text(accounts[index].name.isEmpty ? accounts[index].configDirectory : accounts[index].name)
                                .tag(Int?.some(index))
                        }
                    }
                }
                .onChange(of: loginRow) { scheduleSave() }
                Text("boxd and ssh machines hold one Claude login, kept in sync with this Mac's. Pick whose.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task {
            await load()
            // A folder created since (the first `claude` run in it) gets
            // its hooks and skill now.
            Task.detached { ClaudeAccountsSetup.refresh() }
        }
    }



    @ViewBuilder
    private func accountRows(_ index: Int) -> some View {
        let account = accounts.indices.contains(index) ? accounts[index] : ClaudeAccount(name: "", configDirectory: "")
        TextField("Name", text: binding(index, \.name), prompt: Text("Work"))
        TextField("Config folder", text: binding(index, \.configDirectory), prompt: Text("~/.claude-work"))
            .font(.system(.body, design: .monospaced))
        ForEach(problems(of: account, at: index), id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
        TextField("Project folders", text: projectsBinding(index), prompt: Text("~/work, ~/clients/acme"), axis: .vertical)
            .font(.system(.body, design: .monospaced))
        Text("Comma or line separated. A folder and everything under it; the longest match wins.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        TextField("GitHub login", text: githubBinding(index), prompt: Text("optional, for gh in these projects"))
        if let installed = hooksInstalled[account.configDirectory] {
            HStack {
                Label("Hooks", systemImage: installed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Spacer()
                if !installed {
                    Button("Install Hooks") { installHooks(for: account) }
                }
            }
        }
    }

    // MARK: Validation

    private func problems(of account: ClaudeAccount, at index: Int) -> [String] {
        let home = NSHomeDirectory()
        guard let folder = ClaudeConfigLayout.expand(account.configDirectory, home: home) else {
            return ["Use a full path or one starting with ~/. This account is ignored until then."]
        }
        guard ClaudeConfigLayout.isUsableConfigDirectory(folder, home: home) else {
            return ["Not the home folder or above it. This account is ignored until then."]
        }
        var out: [String] = []
        if folder == home + "/.claude" {
            out.append("~/.claude is always included; this account only adds its project folders.")
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue {
            out.append("No such folder yet. Run `CLAUDE_CONFIG_DIR=\(account.configDirectory) claude` once to create it and log in.")
        }
        let duplicate = accounts.indices.contains { other in
            other != index && ClaudeConfigLayout.expand(accounts[other].configDirectory, home: home) == folder
        }
        if duplicate { out.append("Another account uses this folder.") }
        let relative = account.projectPaths.filter { ClaudeConfigLayout.expand($0, home: home) == nil }
        if !relative.isEmpty {
            out.append("Ignored project folders (not full paths): \(relative.joined(separator: ", "))")
        }
        return out
    }

    // MARK: Bindings

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<ClaudeAccount, String>) -> Binding<String> {
        Binding(
            get: { accounts.indices.contains(index) ? accounts[index][keyPath: keyPath] : "" },
            set: { value in
                guard accounts.indices.contains(index) else { return }
                accounts[index][keyPath: keyPath] = value
                scheduleSave()
            }
        )
    }

    private func projectsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { accounts.indices.contains(index) ? accounts[index].projectPaths.joined(separator: ", ") : "" },
            set: { value in
                guard accounts.indices.contains(index) else { return }
                accounts[index].projectPaths = value
                    .split(whereSeparator: { $0 == "," || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                scheduleSave()
            }
        )
    }

    private func githubBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { accounts.indices.contains(index) ? (accounts[index].githubUser ?? "") : "" },
            set: { value in
                guard accounts.indices.contains(index) else { return }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                accounts[index].githubUser = trimmed.isEmpty ? nil : trimmed
                scheduleSave()
            }
        )
    }

    // MARK: Load / save

    private func load() async {
        // An edit still waiting to be saved lands first.
        await saveTask?.value
        do {
            let settings = try await settingsStore.read()
            accounts = settings.claudeAccounts
            let home = NSHomeDirectory()
            let saved = settings.claudeMachineLoginDirectory.flatMap { ClaudeConfigLayout.expand($0, home: home) }
            loginRow = saved.flatMap { saved in
                settings.claudeAccounts.firstIndex { ClaudeConfigLayout.expand($0.configDirectory, home: home) == saved }
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        refreshHookStatus()
        loaded = true
    }

    private func scheduleSave() {
        guard loaded, loadError == nil else { return }
        let accounts = self.accounts
        let machineLogin = loginRow.flatMap { accounts.indices.contains($0) ? accounts[$0].configDirectory : nil } ?? ""
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // A settings file that cannot be read is never replaced by
            // defaults: that would drop every other setting.
            guard var settings = try? await settingsStore.read() else { return }
            let saved = accounts.filter { !$0.configDirectory.trimmingCharacters(in: .whitespaces).isEmpty }
            let login = machineLogin.isEmpty ? nil : machineLogin
            guard settings.claudeAccounts != saved || settings.claudeMachineLoginDirectory != login else { return }
            settings.claudeAccounts = saved
            settings.claudeMachineLoginDirectory = login
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            refreshHookStatus()
        }
    }

    /// A folder the row's hook status and button apply to: usable, and one
    /// Claude Code has used (otherwise the row says to run it once).
    private func claudeFolder(of account: ClaudeAccount) -> String? {
        let home = NSHomeDirectory()
        guard let folder = ClaudeConfigLayout.expand(account.configDirectory, home: home),
              ClaudeConfigLayout.isUsableConfigDirectory(folder, home: home),
              ClaudeConfigLayout.looksLikeClaudeFolder(folder) else { return nil }
        return folder
    }

    private func refreshHookStatus() {
        var status: [String: Bool] = [:]
        for account in accounts {
            guard let folder = claudeFolder(of: account) else { continue }
            status[account.configDirectory] = HookManager.isInstalled(for: .claude, settingsPath: folder + "/settings.json")
        }
        hooksInstalled = status
    }

    private func installHooks(for account: ClaudeAccount) {
        guard let folder = claudeFolder(of: account) else { return }
        let path = folder + "/settings.json"
        guard HookManager.isRewritable(path) else {
            KanbanCodeLog.warn("hooks", "Not installing hooks into \(path): not a JSON object")
            return
        }
        ClaudeAccountsSetup.serialized {
            // The folder keeps a status line of its own.
            try? HookManager.install(for: .claude, settingsPaths: [path], replacingOwnStatusLine: false)
            _ = try? VaultHook.install(settingsPath: path)
            _ = try? PermissionHook.install(settingsPath: path)
        }
        refreshHookStatus()
    }
}
