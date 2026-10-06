import SwiftUI
import KanbanCodeCore

/// Settings > Sync: the agent setup kept the same on every peer master
/// (Settings > Remote Control > Peers). Edits here win over every peer's
/// copy of this list, so the box follows the Mac.
struct SyncSettingsView: View {
    @State private var entries: [SyncEntry] = []
    @State private var statuses: [String: SyncEntryStatus] = [:]
    @State private var newMode: SyncEntryMode = .mirror
    @State private var newPath = ""
    @State private var editingExcludes: String?
    @State private var excludesText = ""
    @State private var editingKeys: String?
    @State private var keysText = ""
    @State private var editingPaths: String?
    @State private var pathsText = ""

    private var engine: AgentSyncEngine { AppComposition.shared.agentSync }

    var body: some View {
        Form {
            section(.git, title: "Git repositories",
                    footer: "Cloned where missing, fetched and fast-forwarded every two minutes and when a peer pushes; local commits are pushed. A diverged clone is never forced.")
            section(.mirror, title: "Mirrored files",
                    footer: "The newest version of each file wins; deletions travel too. The home folder is rewritten in text files and symlink targets. A file that differed on first sync keeps the local copy as <name>.sync-prev.")
            section(.json, title: "Settings keys",
                    footer: "For a JSON settings file that also holds what belongs to one machine: only the named top-level keys are kept the same, newest wins, and the rest of the file is left as it is. A machine that does not have the file yet is skipped.")
            section(.optmem, title: "OptMem",
                    footer: "The home (the always-on master unless set) keeps the memory. Other machines forward memo note, nap and forget to it, queue them while it is unreachable, and read a mirrored copy.")
            Section("Add") {
                HStack {
                    Picker("", selection: $newMode) {
                        Text("Git").tag(SyncEntryMode.git)
                        Text("Mirror").tag(SyncEntryMode.mirror)
                        Text("Settings keys").tag(SyncEntryMode.json)
                        Text("OptMem").tag(SyncEntryMode.optmem)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    TextField("~/path", text: $newPath)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Restore defaults") { save(SyncConfig.defaults.entries) }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func section(_ mode: SyncEntryMode, title: String, footer: String) -> some View {
        Section {
            let rows = entries.filter { $0.mode == mode }
            if rows.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            }
            ForEach(rows) { entry in
                row(entry)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ entry: SyncEntry) -> some View {
        let status = statuses[entry.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(color(entry, status))
                    .frame(width: 8, height: 8)
                Text(entry.path).font(.body.monospaced())
                Spacer()
                if entry.mode == .mirror {
                    Button("Excludes") {
                        editingExcludes = entry.id
                        excludesText = entry.excludes.joined(separator: ", ")
                    }
                    .controlSize(.small)
                }
                if entry.mode == .json {
                    Button("Keys") {
                        editingKeys = entry.id
                        keysText = entry.keys.joined(separator: ", ")
                    }
                    .controlSize(.small)
                }
                if entry.copiesFiles {
                    Button("Paths") {
                        editingPaths = entry.id
                        pathsText = entry.paths.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    }
                    .controlSize(.small)
                    .help("The path on a machine that keeps this somewhere else")
                }
                Toggle("", isOn: Binding(
                    get: { entry.enabled },
                    set: { value in update(entry.id) { $0.enabled = value } }
                ))
                .labelsHidden()
                Button("Remove", role: .destructive) { save(entries.filter { $0.id != entry.id }) }
                    .controlSize(.small)
            }
            Text(detail(entry, status))
                .font(.caption)
                .foregroundStyle(status?.level == .warning || status?.level == .error ? Color.orange : Color.secondary)
                .textSelection(.enabled)
            if editingExcludes == entry.id {
                HStack {
                    TextField("*.log, .trash/", text: $excludesText)
                        .onSubmit { commitExcludes(entry.id) }
                    Button("Save") { commitExcludes(entry.id) }.controlSize(.small)
                }
            }
            if editingKeys == entry.id {
                HStack {
                    TextField("theme, fontSize", text: $keysText)
                        .onSubmit { commitKeys(entry.id) }
                    Button("Save") { commitKeys(entry.id) }.controlSize(.small)
                }
            }
            if editingPaths == entry.id {
                HStack {
                    TextField("machine name=~/path on it", text: $pathsText)
                        .onSubmit { commitPaths(entry.id) }
                    Button("Save") { commitPaths(entry.id) }.controlSize(.small)
                }
            }
            if entry.mode == .optmem {
                HStack {
                    Text("Home").foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { entry.home ?? "" },
                        set: { value in update(entry.id) { $0.home = value.isEmpty ? nil : value } }
                    ), prompt: Text("the always-on master"))
                    .labelsHidden()
                    Text("ssh fallback").foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { entry.ssh ?? "" },
                        set: { value in update(entry.id) { $0.ssh = value.isEmpty ? nil : value } }
                    ), prompt: Text("none, e.g. root@host"))
                    .labelsHidden()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ entry: SyncEntry, _ status: SyncEntryStatus?) -> Color {
        guard entry.enabled else { return .secondary }
        switch status?.level {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .info, nil: return .blue
        }
    }

    private func detail(_ entry: SyncEntry, _ status: SyncEntryStatus?) -> String {
        guard entry.enabled else { return "off" }
        var parts: [String] = []
        if let status {
            parts.append(status.message)
            if let count = status.count {
                let noun = switch entry.mode {
                case .optmem: "memor" + (count == 1 ? "y" : "ies")
                case .json: "key" + (count == 1 ? "" : "s")
                default: "file" + (count == 1 ? "" : "s")
                }
                parts.append("\(count) \(noun)")
            }
            if let last = status.lastSync {
                parts.append("synced " + RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))
            }
        } else {
            parts.append("waiting for the first round")
        }
        if entry.mode == .json {
            parts.append(entry.keys.isEmpty ? "no keys named yet" : "keys " + entry.keys.joined(separator: " "))
        }
        for (machine, path) in entry.paths.sorted(by: { $0.key < $1.key }) {
            parts.append("\(path) on \(machine)")
        }
        if entry.mode == .mirror {
            let extra = entry.excludes.filter { !SyncConfig.defaultExcludes.contains($0) }
            let dropped = SyncConfig.defaultExcludes.filter { !entry.excludes.contains($0) }
            if !extra.isEmpty { parts.append("also excludes " + extra.joined(separator: " ")) }
            if !dropped.isEmpty { parts.append("syncs " + dropped.joined(separator: " ")) }
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let config = await engine.currentConfig()
        let current = await engine.entryStatuses()
        if config.entries != entries { entries = config.entries }
        if current != statuses { statuses = current }
    }

    private func save(_ new: [SyncEntry]) {
        entries = new
        Task { await engine.setEntries(new) }
    }

    private func update(_ id: String, _ change: (inout SyncEntry) -> Void) {
        var copy = entries
        guard let index = copy.firstIndex(where: { $0.id == id }) else { return }
        change(&copy[index])
        save(copy)
    }

    private func add() {
        var path = newPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        let entry = SyncEntry(mode: newMode, path: path,
                              excludes: newMode == .mirror ? SyncConfig.defaultExcludes : [])
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        save(entries + [entry])
        newPath = ""
    }

    private func commitKeys(_ id: String) {
        let keys = keysText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update(id) { $0.keys = keys }
        editingKeys = nil
    }

    private func commitPaths(_ id: String) {
        var paths: [String: String] = [:]
        for pair in pathsText.split(separator: ",") {
            let sides = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2, !sides[0].isEmpty, !sides[1].isEmpty else { continue }
            paths[sides[0]] = sides[1]
        }
        update(id) { $0.paths = paths }
        editingPaths = nil
    }

    private func commitExcludes(_ id: String) {
        let patterns = excludesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update(id) { $0.excludes = patterns }
        editingExcludes = nil
    }
}
