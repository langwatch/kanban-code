import SwiftUI
import KanbanCore

struct SettingsView: View {
    @State private var hooksInstalled = false
    @State private var ghAvailable = false
    @State private var tmuxAvailable = false
    @State private var mutagenAvailable = false

    var body: some View {
        TabView {
            GeneralSettingsView(
                hooksInstalled: $hooksInstalled,
                ghAvailable: ghAvailable,
                tmuxAvailable: tmuxAvailable,
                mutagenAvailable: mutagenAvailable
            )
            .tabItem { Label("General", systemImage: "gear") }

            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }

            RemoteSettingsView()
                .tabItem { Label("Remote", systemImage: "network") }
        }
        .frame(width: 450, height: 350)
        .task {
            await checkAvailability()
        }
    }

    private func checkAvailability() async {
        hooksInstalled = HookManager.isInstalled()
        ghAvailable = await GhCliAdapter().isAvailable()
        tmuxAvailable = await TmuxAdapter().isAvailable()
        mutagenAvailable = await MutagenAdapter().isAvailable()
    }
}

struct GeneralSettingsView: View {
    @Binding var hooksInstalled: Bool
    let ghAvailable: Bool
    let tmuxAvailable: Bool
    let mutagenAvailable: Bool

    var body: some View {
        Form {
            Section("Integrations") {
                HStack {
                    Label("Claude Code Hooks", systemImage: hooksInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                    Spacer()
                    if !hooksInstalled {
                        Button("Install") {
                            do {
                                try HookManager.install()
                                hooksInstalled = true
                            } catch {
                                // Show error
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Text("Installed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                statusRow("tmux", available: tmuxAvailable)
                statusRow("GitHub CLI (gh)", available: ghAvailable)
                statusRow("Mutagen", available: mutagenAvailable)
            }

            Section("Settings File") {
                HStack {
                    Text("~/.kanban/settings.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in Editor") {
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban/settings.json")
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func statusRow(_ name: String, available: Bool) -> some View {
        HStack {
            Label(name, systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Spacer()
            Text(available ? "Available" : "Not found")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

struct NotificationSettingsView: View {
    @State private var pushoverToken = ""
    @State private var pushoverUser = ""

    var body: some View {
        Form {
            Section("Pushover") {
                TextField("App Token", text: $pushoverToken)
                TextField("User Key", text: $pushoverUser)
                Text("Get your keys at pushover.net")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct RemoteSettingsView: View {
    @State private var remoteHost = ""
    @State private var remotePath = ""
    @State private var localPath = ""

    var body: some View {
        Form {
            Section("SSH") {
                TextField("Remote Host", text: $remoteHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Remote Path", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Local Path", text: $localPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
