import KanbanCodeCore
import SwiftUI

/// Settings > Vault, the scrubber: its schedule, a manual run, the last
/// real run of every master, and the extra paths it reads. The result of a
/// dry run shows only while this view stays open (docs/vault.md, "Scrubber").
struct ScrubSettingsSection: View {
    @State private var status: ScrubStatus?
    @State private var peers: [String: ScrubStatus] = [:]
    @State private var enabled = true
    @State private var time = Date()
    @State private var paths: [String] = []
    @State private var patterns = true
    /// When Dry Run was pressed in this view; older dry runs are not shown.
    @State private var dryRunSince: Date?
    @State private var details: [Named]?
    @State private var showPaths = false

    private var scrubber: SecretScrubber { AppComposition.shared.scrubber }
    static let docs = URL(string: "https://github.com/langwatch/kanban-code/blob/main/docs/vault.md#scrubber")!

    struct Named: Identifiable {
        var id: String { name }
        var name: String
        var report: ScrubReport
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Scrub secrets from transcripts daily at", isOn: $enabled)
                        .onChange(of: enabled) { _, _ in save() }
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 90)
                        .disabled(!enabled)
                        .onChange(of: time) { _, _ in save() }
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                        Text(status?.progress ?? "running").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Dry Run") { run(dryRun: true) }
                        .disabled(running)
                        .help("Count what a run would replace, on every master. Nothing changes.")
                    Button("Run Now") { run(dryRun: false) }
                        .disabled(running)
                    Button(paths.isEmpty ? "Paths..." : "Paths (\(paths.count))...") { showPaths = true }
                        .help("Extra files and folders to scrub, besides the transcripts and Kanban's own stores.")
                    Button {
                        NSWorkspace.shared.open(Self.docs)
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("What the scrubber reads and changes")
                }
                ForEach(machines, id: \.name) { machine in
                    HStack(spacing: 6) {
                        Text(Self.summary(machine.name, machine.status.lastRun))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let report = machine.status.lastRun, !report.errors.isEmpty {
                            Button("Details") { details = [Named(name: machine.name, report: report)] }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                if !dryRuns.isEmpty {
                    HStack(spacing: 6) {
                        Text(Self.drySummary(dryRuns)).font(.caption)
                        Button("Details") { details = dryRuns }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Text("Local files only: rotate a key that leaked.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(4)
        }
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            ScrubDetailsSheet(reports: details ?? [])
        }
        .sheet(isPresented: $showPaths) {
            ScrubPathsSheet(paths: paths) { new in
                paths = new
                save()
            }
        }
        .task {
            await load(first: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(running ? 2 : 15))
                await load(first: false)
            }
        }
    }

    private var machines: [(name: String, status: ScrubStatus)] {
        var all: [(name: String, status: ScrubStatus)] = []
        if let status { all.append(("This Mac", status)) }
        all += peers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return all
    }

    private var running: Bool {
        machines.contains { $0.status.running }
    }

    /// The dry runs started from this view, one per master, once they finish.
    private var dryRuns: [Named] {
        guard let since = dryRunSince else { return [] }
        return machines.compactMap { machine in
            guard let report = machine.status.lastDryRun, report.startedAt >= since.addingTimeInterval(-2) else { return nil }
            return Named(name: machine.name, report: report)
        }
    }

    static func summary(_ name: String, _ report: ScrubReport?) -> String {
        guard let report else { return "\(name): no run yet" }
        let when = report.finishedAt.formatted(date: .abbreviated, time: .shortened)
        if let note = report.note { return "\(name), \(when): \(note)" }
        var text = "\(name), \(when): replaced \(report.replacements) values in \(report.filesWithSecrets) files"
        if !report.errors.isEmpty { text += ", \(report.errors.count) error\(report.errors.count == 1 ? "" : "s")" }
        return text
    }

    static func drySummary(_ runs: [Named]) -> String {
        "Dry run: " + runs.map { run in
            run.report.note.map { "\(run.name): \($0)" }
                ?? "\(run.name) would replace \(run.report.replacements) values in \(run.report.filesWithSecrets) files"
        }.joined(separator: "; ")
    }

    private func load(first: Bool) async {
        let current = await scrubber.status()
        status = current
        if first {
            enabled = current.schedule.enabled
            paths = current.schedule.paths
            patterns = current.schedule.patterns
            time = Calendar.current.date(bySettingHour: current.schedule.hour, minute: current.schedule.minute, second: 0, of: Date()) ?? Date()
        }
        peers = await scrubber.peerStatuses()
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = ScrubSchedule(enabled: enabled, hour: parts.hour ?? 4, minute: parts.minute ?? 30, paths: paths, patterns: patterns)
        guard schedule != status?.schedule else { return }
        status?.schedule = schedule
        Task { await scrubber.setSchedule(schedule, share: true) }
    }

    private func run(dryRun: Bool) {
        if dryRun { dryRunSince = Date() } else { dryRunSince = nil }
        Task {
            await scrubber.start(dryRun: dryRun)
            await scrubber.runOnPeers(dryRun: dryRun)
            await load(first: false)
        }
    }
}

/// Counts per file of one or more runs. Paths, names and counts, never a value.
struct ScrubDetailsSheet: View {
    let reports: [ScrubSettingsSection.Named]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(reports) { run in
                    Section {
                        ForEach(run.report.errors, id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        ForEach(run.report.files, id: \.path) { file in
                            HStack {
                                Text(file.path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .help(file.path)
                                Spacer()
                                Text(Self.count(file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(Self.header(run))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 720, height: 460)
    }

    static func header(_ run: ScrubSettingsSection.Named) -> String {
        let r = run.report
        var text = "\(run.name): \(r.replacements) values in \(r.filesWithSecrets) files"
        if r.newSecrets > 0 { text += ", \(r.newSecrets) not in the vault" }
        if r.filesLive > 0 { text += ", \(r.filesLive) files in use skipped" }
        if r.filesWithSecrets > r.files.count { text += " (the \(r.files.count) files with the most)" }
        return text
    }

    static func count(_ file: ScrubFileReport) -> String {
        if let error = file.error { return error }
        let total = file.known + file.new
        return file.live == true ? "\(total), in use" : "\(total)"
    }
}

/// The extra files and folders the scrubber reads, on every master.
struct ScrubPathsSheet: View {
    @State var paths: [String]
    let save: ([String]) -> Void
    @State private var newPath = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extra files and folders").font(.headline)
            List {
                if paths.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                }
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Text(path).font(.body.monospaced())
                        Spacer()
                        Button("Remove", role: .destructive) {
                            paths.removeAll { $0 == path }
                            save(paths)
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                TextField("~/path", text: $newPath)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 320)
    }

    private func add() {
        let path = ScrubSchedule.portable(newPath, home: NSHomeDirectory())
        guard !path.isEmpty else { return }
        if !paths.contains(path) {
            paths.append(path)
            save(paths)
        }
        newPath = ""
    }
}
