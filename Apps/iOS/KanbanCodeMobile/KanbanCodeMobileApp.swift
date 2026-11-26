import SwiftUI
import KanbanCodeRemoteKit

@main
struct KanbanCodeMobileApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var servers: ServerStore
    @State private var fleet: FleetModel
    @State private var pairing = PairingCoordinator()

    init() {
        let servers = ServerStore()
        _servers = State(initialValue: servers)
        _fleet = State(initialValue: FleetModel(store: servers))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(servers)
                .environment(fleet)
                .environment(pairing)
                .onOpenURL { url in
                    // kanbancode://attention/<id> and kanbancode://card/<id> open a request or a card.
                    if url.scheme == "kanbancode", url.host() == "attention" {
                        NotificationCenter.default.post(name: .openAttention, object: url.pathComponents.dropFirst().first)
                        return
                    }
                    if url.scheme == "kanbancode", url.host() == "card", let id = url.pathComponents.dropFirst().first {
                        NotificationCenter.default.post(name: .openCard, object: id)
                        return
                    }
                    pairing.open(url.absoluteString, into: servers)
                }
                .task { await pairFromEnvironment() }
                .task { PushRegistry.shared.attach(servers) }
                .onChange(of: servers.tokenRevision) { PushRegistry.shared.resync() }
        }
    }

    /// UI tests pair through the launch environment: KANBANCODE_PAIR_LINK
    /// (the primary) and KANBANCODE_PAIR_LINKS (more masters, space
    /// separated). KANBANCODE_PAIR_ONLY=1 forgets every other master.
    private func pairFromEnvironment() async {
        let env = ProcessInfo.processInfo.environment
        let texts = ([env["KANBANCODE_PAIR_LINK"]] + (env["KANBANCODE_PAIR_LINKS"] ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init))
            .compactMap { $0 }.filter { !$0.isEmpty }
        let links = texts.compactMap(RemotePairLink.parse)
        guard !links.isEmpty else { return }
        if env["KANBANCODE_PAIR_ONLY"] == "1" { servers.keepOnly(Set(links.map(\.baseURL))) }
        for (index, link) in links.enumerated() {
            await pairing.pair(link, into: servers, makePrimary: index == 0)
        }
    }
}

extension Notification.Name {
    /// Opens the attention list; `object` is the request id to show, if any.
    static let openAttention = Notification.Name("openAttention")
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
    func pair(_ link: RemotePairLink, into store: ServerStore, makePrimary: Bool = false) async -> Bool {
        isChecking = true
        defer { isChecking = false }
        let client = RemoteClient(link: link)
        do {
            _ = try await client.me()
            let health = try? await client.health()
            let name = link.name ?? health?.hostName ?? link.baseURL.host() ?? "Mac"
            store.add(link: link, name: name, makePrimary: makePrimary)
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
    @Environment(FleetModel.self) private var fleet
    @Environment(PairingCoordinator.self) private var pairing

    var body: some View {
        Group {
            if servers.servers.isEmpty {
                NavigationStack { PairingView(isFirstRun: true) }
            } else {
                BoardScreen(fleet: fleet)
            }
        }
        .task { fleet.sync() }
        .onChange(of: servers.servers) { fleet.sync() }
        .onChange(of: servers.tokenRevision) { fleet.sync() }
        .overlay {
            if pairing.isChecking {
                ProgressView("Pairing")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Pairing failed", isPresented: Binding(
            get: { pairing.error != nil && !servers.servers.isEmpty },
            set: { if !$0 { pairing.error = nil } }
        )) {
            Button("OK", role: .cancel) { pairing.error = nil }
        } message: {
            Text(pairing.error ?? "")
        }
    }
}
