import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
#if canImport(Glibc)
import Glibc
#endif

// Headless Kanban Code master: the remote control API (docs/remote-control.md)
// over the kanban home of this machine, for hosts without the Mac app.
//
//   kanban-code-server                      serve on loopback + Tailscale, port from settings (7780)
//   kanban-code-server pair <name> [--scope full|agent|peer|terminal]
//                                           add a device, print its token and pair link

struct ServerOptions {
    var home = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
    var port: Int?
    var devicesPath: String?
    var loopbackOnly = false
    var hostName: String?
    var pairName: String?
    var reconciles = true
    var scope: RemoteScope = .full

    var devicesFile: String {
        devicesPath ?? (home as NSString).appendingPathComponent("remote/devices.json")
    }

    static func parse(_ args: [String]) -> ServerOptions {
        var o = ServerOptions()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { usage("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "pair": o.pairName = value()
            case "--home": o.home = value()
            case "--port": o.port = Int(value())
            case "--devices": o.devicesPath = value()
            case "--scope": o.scope = RemoteScope(rawValue: value()) ?? .full
            case "--host-name": o.hostName = value()
            case "--loopback-only": o.loopbackOnly = true
            case "--reconcile": o.reconciles = true
            case "--no-reconcile": o.reconciles = false
            case "-h", "--help": usage(nil)
            default: usage("unknown argument \(args[i])")
            }
            i += 1
        }
        return o
    }

    static func usage(_ error: String?) -> Never {
        if let error { FileHandle.standardError.write(Data("error: \(error)\n\n".utf8)) }
        say("""
        usage: kanban-code-server [--home <dir>] [--port <n>] [--devices <path>] [--host-name <name>] [--loopback-only] [--no-reconcile]
               kanban-code-server pair <name> [--scope full|agent|peer|terminal] [--home <dir>] [--devices <path>]

          --home       kanban home (default ~/.kanban-code): links.json, settings.json, remote/devices.json
          --port       listen port (default: settings remoteControl.port, else \(RemoteAPI.defaultPort))
          --host-name  name clients show for this machine (default: the host name)
          --no-reconcile  do not keep the cards in step with their sessions (on by default; only the
                       sessions this master launched or adopted have cards)
          pair         adds a device and prints its token and kanbancode:// pair link; a running
                       server picks the device up without a restart
        """)
        exit(error == nil ? 0 : 2)
    }
}

/// Unbuffered, so journald sees each line at once.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// Before any thread starts: see ProcessMemory for why the server needs it.
ProcessMemory.tune()

signal(SIGPIPE, SIG_IGN)

// A server started by hand from a card's shell, or from an ssh login that
// carried a card's variables, must not hand them to the sessions it starts.
InheritedSessionEnvironment.scrub()

let options = ServerOptions.parse(Array(CommandLine.arguments.dropFirst()))
let devices = RemoteDeviceStore(path: options.devicesFile)
let settings = try? await SettingsStore(basePath: options.home).read()
let port = options.port ?? settings?.remoteControl.port ?? RemoteAPI.defaultPort
let hostName = options.hostName ?? RemoteControlServer.defaultHostName

if let name = options.pairName {
    let (device, token) = try devices.add(name: name, scope: options.scope)
    let address = RemoteNetworkAddresses.tailscale().first(where: { !$0.contains(":") }) ?? RemoteNetworkAddresses.loopback
    let base = "http://\(address):\(port)"
    say("paired \(device.name) (\(device.scope.rawValue)), id \(device.id)")
    say("token: \(token)")
    say("pair link: \(RemotePairLink.make(url: base, token: token, name: hostName))")
    exit(0)
}

let master = ServerMaster(home: options.home, reconciles: options.reconciles)
await master.start()
let host = MasterRemoteControlHost(engine: master.engine)
let peerServer = BoardPeerLinksServer(store: master.store, peerSync: master.peerSync)

let scrubber = SecretScrubber(vault: master.vault, machine: await master.vault.broker.machine) { [peerSync = master.peerSync] in
    await peerSync.configuredPeers()
}
Task.detached(priority: .utility) { await scrubber.runSchedule() }
Task.detached(priority: .utility) { await ProcessMemory.runMaintenance() }

let loopbackOnly = options.loopbackOnly
let server = RemoteControlServer(
    host: host,
    devices: devices,
    port: port,
    bindAddresses: { loopbackOnly ? [RemoteNetworkAddresses.loopback] : RemoteNetworkAddresses.bindable() },
    options: .init(appVersion: KanbanCodeServerVersion.current, hostName: hostName),
    peerServer: peerServer,
    syncEngine: master.agentSync,
    vault: master.vault,
    scrubber: scrubber
)

do {
    try await server.start()
} catch {
    fail("\(error)")
}
say("kanban-code-server \(KanbanCodeServerVersion.current) on \(server.listeningAddresses.joined(separator: ", ")) port \(server.port)")
say("home \(options.home), devices \(devices.path), machine \(master.identity.name) (\(master.identity.id))")

// The API serves the cached board while the first reconcile runs: that pass
// can take half a minute on a loaded host, and clients read it as offline.
Task { await master.run() }

let stop: @Sendable (Int32) -> Void = { _ in
    server.stop()
    exit(0)
}
var signalSources: [any DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { stop(sig) }
    source.resume()
    signalSources.append(source)
}

// Serve until stopped.
while true {
    try await Task.sleep(for: .seconds(3600))
}
