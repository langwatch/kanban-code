import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Files attached to a prompt")
struct PromptFilesTests {
    @Test("file lines go after the text and come back out of it")
    func linesRoundTrip() {
        let text = PromptFiles.appending(paths: ["/home/u/.kanban-code/files/a/demo video.mp4", "/tmp/x.pdf"], to: "look at this\n")
        #expect(text == "look at this\n\n[File: /home/u/.kanban-code/files/a/demo video.mp4]\n[File: /tmp/x.pdf]")
        let split = PromptFiles.split(text)
        #expect(split.text == "look at this")
        #expect(split.paths == ["/home/u/.kanban-code/files/a/demo video.mp4", "/tmp/x.pdf"])
    }

    @Test("files alone make the whole prompt")
    func filesAlone() {
        #expect(PromptFiles.appending(paths: ["/a/b.zip"], to: "  ") == "[File: /a/b.zip]")
        #expect(PromptFiles.appending(paths: [], to: "hi") == "hi")
        #expect(PromptFiles.split("[File: /a/b.zip]") == ("", ["/a/b.zip"]))
    }

    @Test("a mention of the marker inside a sentence or a relative path is text")
    func onlyWholeLines() {
        let text = "the line [File: /a] is how it looks\n[File: relative/path]"
        #expect(PromptFiles.split(text).paths.isEmpty)
        #expect(PromptFiles.split(text).text == text)
    }

    @Test("names keep their extension and lose path parts, control characters and leading dots")
    func safeNames() {
        #expect(PromptFiles.safeName("demo.mp4") == "demo.mp4")
        #expect(PromptFiles.safeName("../../etc/passwd") == "passwd")
        #expect(PromptFiles.safeName(".hidden.txt") == "hidden.txt")
        #expect(PromptFiles.safeName("a\nb\u{0}.pdf") == "ab.pdf")
        #expect(PromptFiles.safeName("") == "file")
        let long = String(repeating: "x", count: 300) + ".mov"
        let safe = PromptFiles.safeName(long)
        #expect(safe.count == 200 && safe.hasSuffix(".mov"))
    }

    @Test("images go inline, every other file goes as a path")
    func typeAcceptance() {
        #expect(PromptFiles.isImage(fileName: "shot.PNG"))
        #expect(PromptFiles.isImage(fileName: "photo.heic"))
        for name in ["demo.mp4", "clip.mov", "spec.pdf", "logs.zip", "notes.txt", "Makefile"] {
            #expect(!PromptFiles.isImage(fileName: name))
        }
    }

    @Test("upload ids are one directory name")
    func uploadIds() {
        #expect(PromptFiles.isValidUploadId("0b6c2c9e-6a2e-4b3e-9f1a-1c2d3e4f5a6b"))
        #expect(!PromptFiles.isValidUploadId("../x"))
        #expect(!PromptFiles.isValidUploadId(""))
        #expect(!PromptFiles.isValidUploadId(String(repeating: "a", count: 65)))
    }

    @Test("a chunk request needs its upload, name, size and offset")
    func chunkParsing() throws {
        let ok = RemotePromptFileChunk.parse(query: ["upload": "u-1", "name": "a.mp4", "size": "10", "offset": "0"], body: Data([1]))
        #expect(try ok.get() == RemotePromptFileChunk(upload: "u-1", name: "a.mp4", size: 10, offset: 0, data: Data([1])))
        for query in [["name": "a", "size": "1", "offset": "0"],
                      ["upload": "u", "size": "1", "offset": "0"],
                      ["upload": "u", "name": "a", "offset": "0"],
                      ["upload": "u", "name": "a", "size": "1", "offset": "-1"]] {
            if case .success = RemotePromptFileChunk.parse(query: query, body: Data()) { Issue.record("took \(query)") }
        }
    }
}
