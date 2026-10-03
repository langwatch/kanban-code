import SwiftUI
import KanbanCodeRemoteKit

/// The paired masters: which one is primary, which are online, pairing
/// another, forgetting one.
struct MachinesView: View {
    let fleet: FleetModel
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var forgetting: SavedServer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(fleet.masters, id: \.server.id) { master in
                        Button {
                            servers.primaryID = master.server.id
                        } label: {
                            HStack {
                                MachineStatusLine(master: master)
                                if master.server.id == fleet.primary?.server.id {
                                    Text("Primary")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityIdentifier("primaryBadge")
                                }
                            }
                        }
                        .tint(.primary)
                        .accessibilityIdentifier("machine-\(master.machineName)")
                        .swipeActions {
                            Button("Forget", role: .destructive) { forgetting = master.server }
                        }
                        .contextMenu {
                            Button("Make primary", systemImage: "star") { servers.primaryID = master.server.id }
                            Button("Forget", systemImage: "trash", role: .destructive) { forgetting = master.server }
                        }
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("The board shows the cards of every machine. Tap one to make it primary: new tasks start there unless you pick another. Keep an always-on machine as primary so the phone has a board while the Mac sleeps.")
                }

                Section {
                    Button("Pair another machine", systemImage: "plus") { showAdd = true }
                        .accessibilityIdentifier("addMachine")
                }

                Section {
                    NavigationLink {
                        VaultDeviceView(fleet: fleet)
                    } label: {
                        Label("Vault key", systemImage: "faceid")
                    }
                    .accessibilityIdentifier("vaultKey")
                } footer: {
                    Text("Lets this phone unlock the secrets that always ask, with Face ID.")
                }
            }
            .navigationTitle("Machines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("machinesDone")
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack { PairingView() }
            }
            .confirmationDialog("Forget \(forgetting?.name ?? "")?", isPresented: Binding(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
            ), titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    if let server = forgetting { servers.remove(server) }
                    forgetting = nil
                }
            } message: {
                Text("Its cards leave the board. Pair it again to bring them back.")
            }
        }
    }
}

#Preview {
    MachinesView(fleet: FleetModel(preview: [BoardModel(preview: PreviewData.board),
                                             BoardModel(preview: PreviewData.boxBoard, name: "rchaves-platform", online: false)]))
        .environment(ServerStore())
}
