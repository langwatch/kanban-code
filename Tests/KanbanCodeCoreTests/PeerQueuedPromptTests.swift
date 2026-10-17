import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Queued prompts on cards another master owns")
struct PeerQueuedPromptTests {
    @Test("a prompt the owner's queue no longer holds has left it, even when the place ids shifted")
    func promptLeftByText() {
        let queue = [RemoteQueuedPrompt(id: "rush-0-abc", text: "two")]
        // "two" moved from place 1 to place 0 when "one" was sent: still queued.
        #expect(!MasterEngine.queuedPromptLeft(promptId: "rush-1-abc", body: "two", queue: queue))
        #expect(MasterEngine.queuedPromptLeft(promptId: "rush-0-def", body: "one", queue: queue))
        #expect(MasterEngine.queuedPromptLeft(promptId: "rush-0-def", body: "one", queue: []))
    }

    @Test("without the text, a prompt is matched by its id")
    func promptLeftById() {
        let queue = [RemoteQueuedPrompt(id: "p1", text: "one")]
        #expect(!MasterEngine.queuedPromptLeft(promptId: "p1", body: nil, queue: queue))
        #expect(MasterEngine.queuedPromptLeft(promptId: "p2", body: nil, queue: queue))
    }

    @Test("rush's two words for a message that left the queue are both recognised")
    func rushLeftQueueMessages() {
        #expect(RushCommandFailed(arguments: ["send"], message: "no such message in the queue").messageLeftQueue)
        #expect(RushCommandFailed(arguments: ["send"], message: "that message has already been sent").messageLeftQueue)
        #expect(!RushCommandFailed(arguments: ["send"], message: "session ed3d7731 didn't answer").messageLeftQueue)
    }

    @Test("an unexpected error reaches the caller as its description, not the error's fields")
    func serverErrorUsesDescription() {
        let long = String(repeating: "x", count: 15_000)
        let error = RushCommandFailed(arguments: ["send", "ed3d7731", "0", "--was", long], message: "session ed3d7731 went away")
        let response = RemoteControlServer.response(for: error)
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(response.status == 500)
        #expect(body.contains("rush send failed: session ed3d7731 went away"))
        #expect(!body.contains(long))
    }
}
