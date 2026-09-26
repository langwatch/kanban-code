import SwiftUI
import KanbanCodeRemoteKit

@main
struct KanbanCodeMobileApp: App {
    @State private var servers = ServerStore()
    @State private var pairing = PairingCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(servers)
                .environment(pairing)
                .onOpenURL { url in pairing.open(url.absoluteString, into: servers) }
                .task {
                    // UI tests pair through the launch environment.
                    if let link = ProcessInfo.processInfo.environment["KANBANCODE_PAIR_LINK"] {
                        pairing.open(link, into: servers)
                    }
                }
        }
    }
}

/// Checks a pairing link against the Mac before saving it.
@Observable
final class PairingCoordinator {
    private(set) var isChecking = false
    var error: String?

    func open(_ text: String, into store: ServerStore) {
        guard let link = RemotePairLink.parse(text) else {
            error = "That is not a Kanban Code pairing link."
            return
        }
        Task { await pair(link, into: store) }
    }

    @discardableResult
    func pair(_ link: RemotePairLink, into store: ServerStore) async -> Bool {
        isChecking = true
        defer { isChecking = false }
        let client = RemoteClient(link: link)
        do {
            _ = try await client.me()
            let health = try? await client.health()
            let name = link.name ?? health?.hostName ?? link.baseURL.host() ?? "Mac"
            store.add(link: link, name: name)
            error = nil
            return true
        } catch {
            self.error = "Could not pair with \(link.baseURL.host() ?? "the Mac"): \(error.localizedDescription)"
            return false
        }
    }
}

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(PairingCoordinator.self) private var pairing

    var body: some View {
        Group {
            if let server = servers.selected {
                BoardScreen(server: server)
                    .id(server.id)
            } else {
                NavigationStack { PairingView(isFirstRun: true) }
            }
        }
        .overlay {
            if pairing.isChecking {
                ProgressView("Pairing")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Pairing failed", isPresented: Binding(
            get: { pairing.error != nil && servers.selected != nil },
            set: { if !$0 { pairing.error = nil } }
        )) {
            Button("OK", role: .cancel) { pairing.error = nil }
        } message: {
            Text(pairing.error ?? "")
        }
    }
}
