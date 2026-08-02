import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Raw byte search")
struct ByteSearchTests {
    private func needles(_ values: [String]) throws -> [[UInt8]] {
        try #require(ByteSearch.asciiNeedles(values))
    }

    @Test("Matching ignores ASCII case on both sides")
    func caseInsensitive() throws {
        let probes = try needles(["pr 4480"])

        #expect("merged PR 4480 today".containsAnyASCII(probes))
        #expect("merged pr 4480 today".containsAnyASCII(probes))
        #expect(!"merged pr 4481 today".containsAnyASCII(probes))
    }

    @Test("Non-ASCII needles opt out rather than fold wrongly")
    func rejectsNonASCII() {
        #expect(ByteSearch.asciiNeedles(["café"]) == nil)
        #expect(ByteSearch.asciiNeedles([]) == nil)
        #expect(ByteSearch.asciiNeedles([""]) == nil)
    }

    @Test("The gate is the run every phrase shares")
    func findsCommonGate() throws {
        let pr = try needles(["#4480", "/pull/4480", "pull/4480", "pr #4480", "pr 4480"])

        let gate = try #require(ByteSearch.commonGate(pr))
        #expect(String(decoding: gate, as: UTF8.self) == "4480")

        // Nothing shared, and a single needle, both mean no gate.
        #expect(ByteSearch.commonGate(try needles(["alpha", "bravo"])) == nil)
        #expect(ByteSearch.commonGate(try needles(["solo"])) == nil)
    }

    @Test("Any phrase that matches also matches the gate")
    func gateNeverHidesAMatch() throws {
        let phrases = ["#4480", "/pull/4480", "pull/4480", "pr #4480", "pr 4480", "\"prnumber\":4480"]
        let probes = try needles(phrases)
        let gate = try #require(ByteSearch.commonGate(probes))

        for phrase in phrases {
            #expect(phrase.containsAnyASCII([gate]), "gate must be present in \(phrase)")
        }
    }

    @Test("A phrase split across two read blocks is still found")
    func findsMatchAcrossBlockBoundary() throws {
        let path = NSTemporaryDirectory() + "kanban-bytesearch-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Land "pull/4480" exactly on the seam between two 4096-byte blocks.
        let phrase = "pull/4480"
        let prefix = String(repeating: "x", count: 4096 - 4)
        try (prefix + phrase + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let probes = try needles([phrase])
        #expect(ByteSearch.fileContainsAny(path: path, needles: probes, chunkSize: 4096))
        #expect(!ByteSearch.fileContainsAny(path: path, needles: try needles(["pull/9999"]), chunkSize: 4096))
    }

    @Test("A missing file is not a match")
    func missingFile() throws {
        #expect(!ByteSearch.fileContainsAny(path: "/nope/does-not-exist.jsonl", needles: try needles(["x1"])))
    }
}
