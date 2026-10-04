import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Observation

/// Runs the remote control server of Settings > Remote Control and holds
/// the paired devices. The server itself runs off the main actor; this
/// controller only starts, stops and reports on it.
@MainActor
@Observable
final class RemoteControlController {
    static let shared = RemoteControlController()

    private(set) var isRunning = false
    private(set) var port = RemoteAPI.defaultPort
    private(set) var addresses: [String] = []
    private(set) var lastError: String?
    /// The Mac's Tailscale MagicDNS name, e.g. `mac.tailnet.ts.net`.
    private(set) var magicDNSName: String?
    private(set) var devices: [RemoteDevice] = []

    @ObservationIgnored let deviceStore = RemoteDeviceStore()
    @ObservationIgnored private var server: RemoteControlServer?
    @ObservationIgnored private var host: MasterRemoteControlHost?
    @ObservationIgnored private var applied: RemoteControlSettings?
    @ObservationIgnored private weak var engine: MasterEngine?
    @ObservationIgnored private var peerServer: (any PeerLinksServing)?
    @ObservationIgnored private var syncEngine: AgentSyncEngine?
    @ObservationIgnored private var vault: VaultService?
    /// Set by the composition root before `attach`.
    @ObservationIgnored var scrubber: SecretScrubber?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    private init() {}

    /// Wires the controller to the app's master engine and starts following
    /// the settings. Called once by the composition root.
    func attach(engine: MasterEngine, peerServer: (any PeerLinksServing)?, syncEngine: AgentSyncEngine?, vault: VaultService?,
                settingsStore: SettingsStore) {
        self.syncEngine = syncEngine
        self.vault = vault
        self.engine = engine
        self.peerServer = peerServer
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .kanbanCodeSettingsChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await RemoteControlController.shared.reload(settingsStore: settingsStore) }
        }
        Task { await reload(settingsStore: settingsStore) }
    }

    func reload(settingsStore: SettingsStore) async {
        // A settings file that can't be read keeps the server as it is: only
        // a setting that says so turns it off.
        guard let settings = try? await settingsStore.read() else { return }
        await apply(settings.remoteControl)
    }

    func apply(_ settings: RemoteControlSettings) async {
        guard settings != applied || (settings.enabled && server == nil) else {
            refreshStatus()
            return
        }
        applied = settings
        stopServer()
        port = settings.port
        guard settings.enabled else {
            refreshStatus()
            return
        }
        guard let engine else { return }
        let host = MasterRemoteControlHost(engine: engine)
        let store = engine.store
        let server = RemoteControlServer(
            host: host, devices: deviceStore, port: settings.port, peerServer: peerServer, syncEngine: syncEngine,
            vault: vault, scrubber: scrubber,
            // The phone using a card this Mac owns keeps the Mac awake for a while.
            activity: { cardId in
                let ownedHere = await MainActor.run { store.state.links[cardId].map(store.state.isOwnedLocally) ?? false }
                if ownedHere { RemoteWakeHold.shared.touch(card: cardId) }
            })
        do {
            try await server.start()
            self.host = host
            self.server = server
            lastError = nil
        } catch {
            server.stop()
            lastError = "\(error)"
            KanbanCodeLog.warn("remote", "remote control did not start: \(error)")
        }
        refreshStatus()
        await refreshMagicDNSName()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        host = nil
    }

    func refreshStatus() {
        isRunning = server?.isRunning ?? false
        addresses = server?.listeningAddresses ?? []
        if let server { port = server.port }
        devices = deviceStore.list().sorted { $0.createdAt > $1.createdAt }
    }

    func refreshMagicDNSName() async {
        magicDNSName = await Self.tailscaleDNSName()
    }

    // MARK: - Devices

    func addDevice(name: String, scope: RemoteScope) throws -> (device: RemoteDevice, token: String) {
        let (device, token) = try deviceStore.add(name: name, scope: scope)
        refreshStatus()
        return (device, token)
    }

    func revoke(deviceId: String) {
        _ = try? deviceStore.revoke(id: deviceId)
        server?.closeConnections(deviceId: deviceId)
        refreshStatus()
    }

    /// The URL a device on the tailnet reaches the server at.
    var baseURL: String {
        if let magicDNSName { return "http://\(magicDNSName):\(port)" }
        if let ip = addresses.first(where: { $0 != RemoteNetworkAddresses.loopback && !$0.contains(":") }) {
            return "http://\(ip):\(port)"
        }
        return "http://127.0.0.1:\(port)"
    }

    func pairLink(token: String) -> String {
        RemotePairLink.make(url: baseURL, token: token, name: RemoteControlServer.defaultHostName)
    }

    /// `Self.DNSName` of `tailscale status --json`, without the final dot.
    nonisolated static func tailscaleDNSName() async -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let tailscale = ShellCommand.findExecutable("tailscale")
                ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let result = try? await ShellCommand.run(tailscale, arguments: ["status", "--json"], timeout: 5),
              result.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
