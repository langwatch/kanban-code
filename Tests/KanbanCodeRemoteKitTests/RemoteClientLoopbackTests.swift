import Testing
import Foundation
@testable import KanbanCodeRemoteKit

/// RemoteClient against the demo server (`swift build --product kanban-code-remote-demo`).
/// Skipped when the binary has not been built.
@Suite("remote client loopback", .serialized, .enabled(if: DemoServer.binary != nil))
struct RemoteClientLoopbackTests {
    @Test("Board, transcript pages, prompts, events and a terminal round trip")
    func roundTrip() async throws {
        let server = try DemoServer.start()
        defer { server.stop() }
        let client = RemoteClient(baseURL: server.url, token: server.token)

        let health = try await client.health()
        #expect(health.apiVersion == RemoteAPI.version)
        #expect(try await client.me().scope == .full)

        let board = try await client.board()
        let live = try #require(board.cards.first { $0.isLive && !$0.terminals.isEmpty })

        let page = try await client.transcript(cardId: live.id, limit: 5)
        #expect(page.messages.count == 5)
        let cursor = try #require(page.olderCursor)
        let older = try await client.transcript(cardId: live.id, limit: 5, before: cursor)
        #expect(Set(older.messages.map(\.id)).isDisjoint(with: page.messages.map(\.id)))

        try await client.sendPrompt(cardId: live.id, text: "from the loopback test", mode: .queue)

        do {
            _ = try await RemoteClient(baseURL: server.url, token: "kc_wrong").board()
            Issue.record("a wrong token was accepted")
        } catch let error as RemoteClientError {
            guard case .unauthorized = error else { Issue.record("expected 401, got \(error)"); return }
        }

        var events = client.events().makeAsyncIterator()
        let first = try await events.next()
        #expect(first?.type == .board)
        var held = first?.board
        try await client.sendPrompt(cardId: live.id, text: "delta please", mode: .now)
        var sawDelta = false
        for _ in 0..<5 {
            guard let event = try await events.next() else { break }
            event.apply(to: &held)
            if event.type == .cards, event.upserted?.contains(where: { $0.id == live.id }) == true {
                sawDelta = true
                break
            }
        }
        #expect(sawDelta)
        #expect(held?.cards.contains { $0.id == live.id } == true)

        let terminal = client.terminal(cardId: live.id, session: live.terminals.last?.sessionName, cols: 80, rows: 24)
        defer { terminal.close() }
        terminal.send("echo kc-loop-$((20+22))\n")
        var seen = ""
        for try await chunk in terminal.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("kc-loop-42") { break }
        }
        #expect(seen.contains("kc-loop-42"))
    }
}

struct DemoServer {
    let process: Process
    let url: URL
    let token: String

    static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".build/debug/kanban-code-remote-demo")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }

    static func start() throws -> DemoServer {
        let port = Int.random(in: 18_000..<19_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kc-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        guard let binary else { throw RemoteClientError.transport("demo server not built") }
        process.executableURL = binary
        process.arguments = ["--port", String(port), "--pair", "loopback", "--devices", dir.appendingPathComponent("devices.json").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var output = ""
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !output.contains("pair link:") {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            output += String(decoding: data, as: UTF8.self)
        }
        let token = try #require(output.split(separator: "\n")
            .first { $0.hasPrefix("token: ") }
            .map { String($0.dropFirst("token: ".count)) })
        return DemoServer(process: process, url: URL(string: "http://127.0.0.1:\(port)")!, token: token)
    }

    func stop() {
        process.terminate()
    }
}
