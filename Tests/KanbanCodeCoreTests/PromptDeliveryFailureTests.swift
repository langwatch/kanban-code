import Testing
@testable import KanbanCodeCore

/// A launch whose assistant never took its first prompt says so on the Mac,
/// naming the card, instead of leaving a card that stopped with no reason.
@Suite("First prompt delivery failure")
struct PromptDeliveryFailureTests {

    @Test("the error names the assistant, the card and where the prompt went")
    func queuedPrompt() {
        let line = MasterEngine.promptDeliveryFailure(
            assistant: .codex, cardName: "Read-only AWS",
            error: "Codex CLI did not become ready within the timeout period", queued: true)
        #expect(line == "Codex CLI in \"Read-only AWS\" did not get its first prompt: Codex CLI did not become ready within the timeout period. The first prompt was not sent and waits in the card's queue. Check its terminal.")
    }

    @Test("a prompt that failed after the assistant was ready is not said to be queued")
    func sentPartly() {
        let line = MasterEngine.promptDeliveryFailure(assistant: .claude, cardName: nil, error: "paste failed", queued: false)
        #expect(line == "Claude Code did not get its first prompt: paste failed. Check its terminal.")
    }
}
