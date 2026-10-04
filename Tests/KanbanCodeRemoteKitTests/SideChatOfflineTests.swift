import Foundation
import Synchronization
import Testing

@testable import KanbanCodeRemoteKit

/// A machine that does not answer until `awake`, then answers at once.
private final class SleepyMachine: Sendable {
    let awake = Mutex(false)
    let starts = Mutex(0)

    var transport: SideChatController.Transport {
        SideChatController.Transport(
            start: { [self] request in
                starts.withLock { $0 += 1 }
                guard awake.withLock({ $0 }) else { throw RemoteClientError.transport("The request timed out.") }
                return RemoteSideChatRun(id: "run1", cardId: "card_1", kind: request.kind, state: .done, text: "All done.")
            },
            poll: { _ in throw RemoteClientError.transport("The request timed out.") },
            cancel: { _ in })
    }
}

@Suite("Side chat with the card's machine offline")
@MainActor
struct SideChatOfflineTests {
    private func settle(until done: @MainActor () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("a request that got no answer reads as the machine being offline")
    func timeoutNamesTheMachine() async throws {
        let machine = SleepyMachine()
        let chat = SideChatController(transport: machine.transport)
        chat.run(.catchup)
        await settle { !chat.state.isRunning }

        let entry = try #require(chat.state.failedEntry)
        #expect(entry.unreachable)
        #expect(entry.error == "The request timed out.")
        #expect(SideChatFailure.text(for: entry, machine: "Studio Mac", machineOffline: false)
            == "Studio Mac is offline. It may be asleep.")
    }

    @Test("an error the machine answered with stays as it is, unless the machine is known to be offline")
    func answeredErrorsStay() {
        var state = SideChatState()
        state.apply(.asked(localId: "local-1", kind: .btw, question: "why?"))
        state.apply(.failed(id: "local-1", message: "This card has no session to ask about."))
        let entry = state.entries[0]
        #expect(!entry.unreachable)
        #expect(SideChatFailure.text(for: entry, machine: "Studio Mac", machineOffline: false) == "This card has no session to ask about.")
        #expect(SideChatFailure.text(for: entry, machine: "Studio Mac", machineOffline: true) == "Studio Mac is offline. It may be asleep.")
        #expect(SideChatFailure.text(for: entry, machine: " ", machineOffline: true) == "The machine is offline. It may be asleep.")
    }

    @Test("which errors mean no answer")
    func unreachableErrors() {
        #expect(SideChatFailure.isUnreachable(RemoteClientError.transport("The request timed out.")))
        #expect(SideChatFailure.isUnreachable(URLError(.timedOut)))
        #expect(!SideChatFailure.isUnreachable(RemoteClientError.conflict("no live session")))
        #expect(!SideChatFailure.isUnreachable(RemoteClientError.server(status: 500, message: "boom")))
        #expect(!SideChatFailure.isUnreachable(RemoteError("refused")))
    }

    @Test("Retry asks the failed question again, in its place")
    func retry() async throws {
        let machine = SleepyMachine()
        let chat = SideChatController(transport: machine.transport)
        chat.run(.catchup)
        await settle { !chat.state.isRunning }
        #expect(chat.state.failedEntry != nil)

        machine.awake.withLock { $0 = true }
        chat.retry()
        await settle { !chat.state.isRunning }

        #expect(machine.starts.withLock { $0 } == 2)
        #expect(chat.state.entries.count == 1)
        #expect(chat.state.failedEntry == nil)
        #expect(chat.state.entries.first?.answer == "All done.")
        #expect(chat.state.entries.first?.question == SideChatState.catchUpQuestion)
        // Nothing failed: Retry does nothing.
        chat.retry()
        #expect(machine.starts.withLock { $0 } == 2)
    }

    @Test("a request made for the human carries the header to the next master")
    func actingForHeader() {
        let client = RemoteClient(baseURL: URL(string: "http://127.0.0.1:7780")!, token: "t")
        #expect(client.makeRequest("GET", "v1/cards/c1/transcript").value(forHTTPHeaderField: RemoteActingFor.header) == nil)
        let forwarded = RemoteActingFor.$owner.withValue(true) { client.makeRequest("GET", "v1/cards/c1/transcript") }
        #expect(forwarded.value(forHTTPHeaderField: RemoteActingFor.header) == "1")
    }
}
