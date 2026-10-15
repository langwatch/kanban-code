import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Chat sends are kept and failures are told")
struct ChatSendSafetyTests {
    @Test("pasted images are kept under the kanban home, in order, and old ones are pruned")
    func chatImagesAreKept() throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("chat-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = ChatImageStore(kanbanHome: home, maxAge: 3600)

        let images = (1...17).map { Data("image \($0)".utf8) }
        let paths = try store.save(images)
        #expect(paths.count == 17)
        #expect(paths.allSatisfy { $0.hasPrefix("\(home)/images/chat/") })
        #expect(paths.map { FileManager.default.contents(atPath: $0) } == images)

        // Two hours on, the next save clears out the first batch.
        let later = try store.save([Data("new".utf8)], now: Date().addingTimeInterval(7200))
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(FileManager.default.fileExists(atPath: later[0]))
    }

    @Test("a failed prompt is kept on the card and journalled; dismissing it lets it go")
    func failedPromptState() {
        var state = AppState()
        let prompt = QueuedPrompt(body: "this one: [Image #1]", imagePaths: ["/k/images/chat/a.png"], humanWrittenAt: .now)
        let effects = Reducer.reduce(state: &state, action: .promptSendFailed(cardId: "card_a", prompt: prompt, message: "box refused it"))
        #expect(state.failedPrompts["card_a"]?.map(\.prompt) == [prompt])
        #expect(state.failedPrompts["card_a"]?.first?.message == "box refused it")
        guard case .journalQueuedPrompt(let cardId, let journalled, let reason) = effects.first else {
            Issue.record("expected a journal effect, got \(effects)")
            return
        }
        #expect(cardId == "card_a" && journalled == prompt && reason == .failed)

        // The same prompt failing again replaces its entry.
        _ = Reducer.reduce(state: &state, action: .promptSendFailed(cardId: "card_a", prompt: prompt, message: "again"))
        #expect(state.failedPrompts["card_a"]?.map(\.message) == ["again"])

        _ = Reducer.reduce(state: &state, action: .dismissFailedPrompt(cardId: "card_a", promptId: prompt.id))
        #expect(state.failedPrompts["card_a"] == nil)
    }

    @Test("every error banner is written to the log")
    func noticesAreLogged() async throws {
        let marker = "send failed \(UUID().uuidString)"
        let state = AppState()
        state.notice = Notice(marker)
        let log = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs/kanban-code-tests.log")
        var logged = false
        for _ in 0..<40 where !logged {
            logged = (try? String(contentsOfFile: log, encoding: .utf8))?.contains("[notice] error shown: \(marker)") == true
            if !logged { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(logged)
    }
}
