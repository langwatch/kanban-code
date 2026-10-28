import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Files kept for prompts")
struct PromptFileStoreTests {
    private func home() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("prompt-files-\(UUID().uuidString)")
    }

    @Test("chunks in order make the file under its own upload directory, with its name")
    func chunksInOrder() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let first = try PromptFileStore.receive(.init(upload: "u1", name: "clip.mov", size: 5, offset: 0, data: Data([1, 2, 3])), kanbanHome: home)
        #expect(!first.isComplete && first.received == 3)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let last = try PromptFileStore.receive(.init(upload: "u1", name: "clip.mov", size: 5, offset: 3, data: Data([4, 5])), kanbanHome: home)
        #expect(last.isComplete)
        #expect(last.path == home + "/files/u1/clip.mov")
        #expect(FileManager.default.contents(atPath: last.path) == Data([1, 2, 3, 4, 5]))
        // The last chunk sent again answers the same file.
        let again = try PromptFileStore.receive(.init(upload: "u1", name: "clip.mov", size: 5, offset: 3, data: Data([4, 5])), kanbanHome: home)
        #expect(again == last)
    }

    @Test("an empty file is whole at once")
    func emptyFile() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let stored = try PromptFileStore.receive(.init(upload: "u2", name: "empty.txt", size: 0, offset: 0, data: Data()), kanbanHome: home)
        #expect(stored.isComplete)
        #expect(FileManager.default.contents(atPath: stored.path) == Data())
    }

    @Test("a chunk that skips bytes, runs past the size or exceeds the limit is refused")
    func refusals() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try PromptFileStore.receive(.init(upload: "u3", name: "a.bin", size: 10, offset: 0, data: Data([1, 2])), kanbanHome: home)
        #expect(throws: PromptFileError.offsetMismatch(expected: 2)) {
            try PromptFileStore.receive(.init(upload: "u3", name: "a.bin", size: 10, offset: 5, data: Data([1])), kanbanHome: home)
        }
        #expect(throws: PromptFileError.self) {
            try PromptFileStore.receive(.init(upload: "u3", name: "a.bin", size: 10, offset: 2, data: Data(count: 9)), kanbanHome: home)
        }
        #expect(throws: PromptFileError.self) {
            try PromptFileStore.receive(.init(upload: "u4", name: "huge.mp4", size: PromptFiles.maxBytes + 1, offset: 0, data: Data()), kanbanHome: home)
        }
        #expect(throws: PromptFileError.offsetMismatch(expected: 0)) {
            try PromptFileStore.receive(.init(upload: "u5", name: "late.bin", size: 4, offset: 2, data: Data([1])), kanbanHome: home)
        }
    }

    @Test("a local file is copied in with its name, and old uploads go")
    func importLocal() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let source = (home as NSString).appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: URL(fileURLWithPath: source))
        let old = try PromptFileStore.receive(.init(upload: "old", name: "x.txt", size: 1, offset: 0, data: Data([1])), kanbanHome: home)
        let oldDirectory = (old.path as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-15 * 24 * 3600)], ofItemAtPath: oldDirectory)

        let copy = try PromptFileStore.importLocal(URL(fileURLWithPath: source), kanbanHome: home)
        #expect(copy.hasPrefix(home + "/files/") && copy.hasSuffix("/report.pdf"))
        #expect(FileManager.default.contents(atPath: copy) == Data("pdf".utf8))
        #expect(!FileManager.default.fileExists(atPath: oldDirectory))
    }
}
