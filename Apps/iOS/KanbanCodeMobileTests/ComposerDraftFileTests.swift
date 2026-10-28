import XCTest
import KanbanCodeRemoteKit
@testable import KanbanCodeMobile

final class ComposerDraftFileTests: XCTestCase {
    /// Drafts made by the tests, kept alive: freeing a main actor object
    /// while XCTest has task locals bound trips the Swift runtime's
    /// isolated deinit (swift_task_deinitOnExecutor) in the simulator.
    @MainActor static var kept: [ComposerDraft] = []

    @MainActor private func makeDraft(_ text: String) -> ComposerDraft {
        let draft = ComposerDraft(preview: text)
        Self.kept.append(draft)
        return draft
    }

    @MainActor func testFileUploadsThenGoesAsAPathLine() {
        let draft = makeDraft("look at this")
        let id = draft.addFile(name: "demo.mov", size: 1_000)

        XCTAssertFalse(draft.filesReady)
        XCTAssertEqual(draft.files.first?.state, .uploading(0))

        draft.setFileProgress(id, sent: 250, total: 1_000)
        XCTAssertEqual(draft.files.first?.state, .uploading(0.25))

        draft.finishFile(id, path: "/home/me/.kanban-code/files/demo.mov")
        XCTAssertTrue(draft.filesReady)
        XCTAssertEqual(draft.filePaths, ["/home/me/.kanban-code/files/demo.mov"])
        XCTAssertEqual(draft.outgoingText("look at this"),
                       "look at this\n\n[File: /home/me/.kanban-code/files/demo.mov]")
    }

    @MainActor func testFilesAloneMakeASendableMessage() {
        let draft = makeDraft("")
        XCTAssertTrue(draft.isEmpty)
        let id = draft.addFile(name: "report.pdf", size: 10)
        XCTAssertFalse(draft.isEmpty)
        draft.finishFile(id, path: "/tmp/report.pdf")
        XCTAssertEqual(draft.outgoingText(""), "[File: /tmp/report.pdf]")
    }

    @MainActor func testProgressAfterFinishOrFailureIsIgnored() {
        let draft = makeDraft("")
        let id = draft.addFile(name: "a.zip", size: 10)
        draft.finishFile(id, path: "/tmp/a.zip")
        draft.setFileProgress(id, sent: 5, total: 10)
        XCTAssertEqual(draft.files.first?.state, .ready("/tmp/a.zip"))

        let other = draft.addFile(name: "b.zip", size: 10)
        draft.failFile(other, message: "the master is away")
        draft.setFileProgress(other, sent: 5, total: 10)
        XCTAssertEqual(draft.files.last?.state, .failed("the master is away"))
        XCTAssertFalse(draft.filesReady)
        XCTAssertEqual(draft.filePaths, ["/tmp/a.zip"])
    }

    @MainActor func testRemoveAndClearDropFiles() {
        let draft = makeDraft("")
        let a = draft.addFile(name: "a.txt", size: 1)
        draft.addFile(name: "b.txt", size: 1)
        draft.removeFile(a)
        XCTAssertEqual(draft.files.map(\.name), ["b.txt"])
        draft.clear()
        XCTAssertTrue(draft.files.isEmpty)
        XCTAssertTrue(draft.isEmpty)
    }

    @MainActor func testLoadTurnsFileLinesBackIntoFiles() {
        let draft = makeDraft("")
        draft.load(text: "see these\n\n[File: /srv/a.pdf]\n[File: /srv/b.mp4]", images: [])
        XCTAssertEqual(draft.text, "see these")
        XCTAssertEqual(draft.files.map(\.name), ["a.pdf", "b.mp4"])
        XCTAssertEqual(draft.filePaths, ["/srv/a.pdf", "/srv/b.mp4"])
        XCTAssertNil(draft.files.first?.size)
    }

    @MainActor func testStashKeepsUploadedFilesAndLeavesUploadingOnes() {
        let draft = makeDraft("draft text")
        let done = draft.addFile(name: "done.pdf", size: 1)
        draft.finishFile(done, path: "/srv/done.pdf")
        draft.addFile(name: "big.mov", size: 100)

        draft.stash()

        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.files.map(\.name), ["big.mov"])
        XCTAssertEqual(draft.stashes.count, 1)
        XCTAssertEqual(draft.stashes.first?.preview, "draft text + 1 file")

        draft.restore()
        XCTAssertEqual(draft.text, "draft text")
        XCTAssertEqual(draft.files.map(\.name), ["big.mov", "done.pdf"])
        XCTAssertEqual(draft.filePaths, ["/srv/done.pdf"])
    }

    @MainActor func testFileIconsByKind() {
        XCTAssertEqual(FileIcon.symbol(for: "clip.MP4"), "film")
        XCTAssertEqual(FileIcon.symbol(for: "spec.pdf"), "doc.richtext")
        XCTAssertEqual(FileIcon.symbol(for: "logs.zip"), "doc.zipper")
        XCTAssertEqual(FileIcon.symbol(for: "notes"), "doc")
    }
}
