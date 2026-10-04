import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Secret scrubber")
struct SecretScrubberTests {
    /// Made up, and written in parts so no scanner takes the source for a real token.
    static let slack = ["xoxb", "1790780979", "437809112233", "Zk3vQ9mT7pLw2Xy8Rb4Nc6Hd"].joined(separator: "-")
    static let dsnPassword = "p4ssW0rd-Zk3vQ9mT7pLw2Xy8"
    static let multiline = "line1 Zk3vQ9mT7pLw\nline2 \"quoted\" 8Rb4Nc6Hd0123"
    static let vendor = "sk-ant-" + "api03-Qm7Xw2Lp9Vt4Zk8Rb3Nc6Hd1Fy5Gj0Us_Ae-TiOoPqWx"

    private func key() -> ScrubKey {
        ScrubKey(identity: Age.Identity.generate())
    }

    private func scanner(_ secrets: [(String, String)], key: ScrubKey) -> ScrubScanner {
        ScrubScanner(entries: secrets.flatMap { ScrubIndex.fingerprints(name: $0.0, value: $0.1, key: key) }, key: key)
    }

    private func scan(_ text: String, with scanner: ScrubScanner) -> [ScrubMatch] {
        Array(text.utf8).withUnsafeBytes { scanner.scan($0) }
    }

    private func rewrite(_ text: String, _ scanner: ScrubScanner, kind: ScrubFileKind) -> String? {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { buf in
            ScrubRewriter.rewrite(line: buf, matches: scanner.scan(buf), kind: kind).map { String(decoding: $0.bytes, as: UTF8.self) }
        }
    }

    @Test("the index holds no value and no part of one")
    func indexHoldsNoValue() throws {
        let entries = ScrubIndex.fingerprints(name: "SLACK_BOT_TOKEN", value: Self.slack, key: key())
        #expect(!entries.isEmpty)
        let text = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(!text.contains(Self.slack))
        #expect(!text.contains("xoxb"))
        #expect(!text.contains(String(Self.slack.suffix(8))))
    }

    @Test("words, paths, hosts and short values are never fingerprinted")
    func plainValuesAreLeftOut() {
        let k = key()
        for value in ["true", "eu-central-1", "postgres", "http://localhost:5560", "/Users/someone/Projects/app",
                      "someone@example.com", "correct horse battery", "short1A"] {
            #expect(ScrubIndex.fingerprints(name: "X", value: value, key: k).isEmpty, "\(value)")
        }
    }

    @Test("a URL is found by its credential and whole, a JSON value by its members")
    func partsOfValues() {
        let url = "postgres://app:\(Self.dsnPassword)@db.internal:5432/app"
        #expect(ScrubIndex.parts(of: url).contains(Self.dsnPassword))
        #expect(ScrubIndex.parts(of: url).contains(url))
        let json = #"{"accessKeyId":"AKIA"# + #"ZK3VQ9MT7PLW2XY8","secretAccessKey":"Zk3vQ9mT7pLw2Xy8Rb4Nc6Hd0Fy5Gj1UsAeTiOoP","region":"eu-central-1"}"#
        let parts = ScrubIndex.parts(of: json)
        #expect(parts.contains("Zk3vQ9mT7pLw2Xy8Rb4Nc6Hd0Fy5Gj1UsAeTiOoP"))
        #expect(!parts.contains("eu-central-1"))
    }

    @Test("a vault value is found raw and as JSON writes it")
    func findsEscapedForms() throws {
        let k = key()
        let s = scanner([("SLACK_BOT_TOKEN", Self.slack), ("NOTE", Self.multiline)], key: k)
        #expect(scan("token=\(Self.slack) ok", with: s).map(\.name) == ["SLACK_BOT_TOKEN"])
        let line = String(decoding: try JSONEncoder().encode(["text": "a \(Self.multiline) b"]), as: UTF8.self)
        #expect(scan(line, with: s).map(\.name) == ["NOTE"])
        let nested = String(decoding: try JSONEncoder().encode(["tool": line]), as: UTF8.self)
        #expect(scan(nested, with: s).map(\.name) == ["NOTE"])
        #expect(scan("nothing here but words and 1234567890 digits", with: s).isEmpty)
    }

    @Test("a JSONL line keeps its length, still parses and reads as the reference")
    func rewritesJSONL() throws {
        let s = scanner([("SLACK_BOT_TOKEN", Self.slack)], key: key())
        let line = #"{"type":"user","message":{"content":"use \#(Self.slack) for \"this\""},"n":1}"# + "\n"
        let out = try #require(rewrite(line, s, kind: .jsonl))
        #expect(out.utf8.count == line.utf8.count)
        #expect(out.hasSuffix("}\n"))
        #expect(!out.contains(Self.slack))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let content = (parsed["message"] as? [String: Any])?["content"] as? String
        let pad = String(repeating: " ", count: Self.slack.utf8.count - "{{vault:SLACK_BOT_TOKEN}}".utf8.count)
        #expect(content == "use {{vault:SLACK_BOT_TOKEN}}\(pad) for \"this\"")
        #expect(parsed["n"] as? Int == 1)
        // Only the bytes of the value differ, so nothing else in the file is written.
        let changed = zip(line.utf8, out.utf8).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let start = line.utf8.distance(from: line.utf8.startIndex, to: line.range(of: Self.slack)!.lowerBound.samePosition(in: line.utf8)!)
        #expect(changed.allSatisfy { $0 >= start && $0 < start + Self.slack.utf8.count })
    }

    @Test("several values in one string and in nested JSON text")
    func rewritesNested() throws {
        let s = scanner([("SLACK_BOT_TOKEN", Self.slack), ("DB", Self.dsnPassword)], key: key())
        let inner = String(decoding: try JSONEncoder().encode(["out": "\(Self.slack) and \(Self.dsnPassword)"]), as: UTF8.self)
        let line = String(decoding: try JSONEncoder().encode(["result": inner, "after": "x"]), as: UTF8.self)
        let out = try #require(rewrite(line, s, kind: .jsonl))
        #expect(out.utf8.count == line.utf8.count)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String])
        let innerParsed = try #require(try JSONSerialization.jsonObject(with: Data(parsed["result"]!.utf8)) as? [String: String])
        let words = innerParsed["out"]!.split(separator: " ").map(String.init)
        #expect(words == ["{{vault:SLACK_BOT_TOKEN}}", "and", "{{vault:DB}}"])
        #expect(parsed["after"] == "x")
    }

    @Test("a name longer than the value gives the fingerprint reference")
    func shortReference() throws {
        let k = key()
        let value = "Zk3vQ9mT7pLw2Xy8Rb4N"
        let name = "some-project/with/a/long/path/dev/A_VERY_LONG_VARIABLE_NAME"
        let s = scanner([(name, value)], key: k)
        let out = try #require(rewrite("key \(value) end\n", s, kind: .text))
        let tag = k.tagHex(value)
        #expect(out == "key {{vault:#\(tag.prefix(9))}} end\n")
        #expect(ScrubIndex.reference(name: name, tag: tag, length: 15) == nil)
    }

    @Test("a text line pads after the reference, so fixed width records keep their width")
    func rewritesText() throws {
        let s = scanner([("SLACK_BOT_TOKEN", Self.slack)], key: key())
        let record = "#62 2026-09-01 key \(Self.slack) noted".padding(toLength: 119, withPad: " ", startingAt: 0) + "\n"
        let out = try #require(rewrite(record, s, kind: .text))
        #expect(out.utf8.count == 120)
        #expect(out.hasPrefix("#62 2026-09-01 key {{vault:SLACK_BOT_TOKEN}} "))
        #expect(out.contains(" noted"))
    }

    @Test("a value that starts inside an escape is left alone")
    func escapeGuard() {
        let value = "nZk3vQ9mT7pLw2Xy8Rb4N"
        let s = scanner([("X", value)], key: key())
        let line = #"{"a":"line\\#(value)"}"#
        #expect(rewrite(line, s, kind: .jsonl) == nil)
    }

    @Test("a vendor key the vault does not hold is found, an identifier that looks like one is not")
    func vendorKeys() {
        let k = key()
        let s = scanner([], key: k)
        let found = scan(#"{"text":"export ANTHROPIC_API_KEY=\#(Self.vendor) and re_render_count_before_update_hook plus sk-spinner-wrapper-container-inner"}"#, with: s)
        #expect(found.count == 1)
        #expect(found.first?.newValue == Self.vendor)
        #expect(found.first?.name == "scrubbed/found/ANTHROPIC_API_KEY_\(k.tagHex(Self.vendor).prefix(8))")
        #expect(scan("sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", with: s).isEmpty)
    }

    @Test("only a key that reads as minted is taken from a format match")
    func plausibleKeys() {
        let run = "Qm7Xw2Lp9Vt4Zk8Rb3Nc6Hd1Fy5Gj0UsAeTiOoPqWxYz12Cv"
        let minted = [
            Self.vendor,
            "sk-" + "lw-" + run,
            "vk-" + "lw-" + String(run.prefix(26)),
            "sk-" + "proj-" + run + "_" + run + "-" + run,
            "sk-" + run,
            "gh" + "p_" + String(run.prefix(36)),
            "sk_" + "live_" + String(run.prefix(24)),
            "re_" + String(run.prefix(8)) + "_" + String(run.suffix(24)),
            Self.slack,
        ]
        for value in minted { #expect(ScrubScanner.plausibleKey(value), "minted \(value.prefix(8))") }

        let made = [
            "sk-" + "lw-test-key-9f8e7d6c5b4a3f2e1d0c",
            "sk-" + "lw-my-secret-key-Qm7Xw2Lp9Vt4Zk8Rb3Nc",
            "sk-" + "proj-abc123def456ghi789jkl012mno345",
            "sk-" + "some-long-slug-with-2-words-in-it-2026",
            "sk-" + String(run.prefix(24)),
            "re_" + "3NxQm7Xw2Lp9Vt4Zk8Rb3Nc6Hd",
            "sk-" + "lw-" + String(repeating: "ab12", count: 12),
            String(repeating: "x", count: 301),
        ]
        for value in made { #expect(!ScrubScanner.plausibleKey(value), "made up \(value.prefix(12))") }
        #expect(!ScrubScanner.plausibleKey(Self.vendor, cutShort: true))

        // A key shown shortened or masked is not a key.
        let s = scanner([], key: key())
        #expect(scan("key \(Self.vendor) end", with: s).count == 1)
        #expect(scan("key \(Self.vendor)... end", with: s).isEmpty)
        #expect(scan("key \(Self.vendor)*** end", with: s).isEmpty)
        #expect(scan("key \(Self.vendor)\u{2026} end", with: s).isEmpty)
        #expect(scan("ANTHROPIC_API_KEY=sk-" + "ant-api03-test-key-0123-not-a-real-one-4567 end", with: s).isEmpty)
    }

    @Test("a sealed secret keeps the fingerprints of the save that set it, and masters share them")
    func indexOutlivesSealing() async throws {
        let dir = NSTemporaryDirectory() + "scrub-index-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider(Age.Identity.generate()))
        try await store.upsert(VaultSecret(name: "SLACK_BOT_TOKEN", value: Self.slack, tier: .ask))
        let index = ScrubIndexStore(store: store)
        let plain = try #require(await store.scrubDocument())
        await index.absorb(plain)
        let before = await index.export().secrets["SLACK_BOT_TOKEN"]
        #expect(before?.fingerprints.isEmpty == false)

        // The document as it reads once the value is sealed to the owner keys.
        var sealed = plain
        sealed.secrets["SLACK_BOT_TOKEN"]?.value = ""
        sealed.secrets["SLACK_BOT_TOKEN"]?.sealed = "sealed-to-the-owner"
        await index.absorb(sealed)
        #expect(await index.export().secrets["SLACK_BOT_TOKEN"] == before)

        // Another master that only ever saw it sealed takes the fingerprints from this one.
        let other = ScrubIndexStore(store: VaultStore(directory: dir + "-other", keys: MemoryVaultKeyProvider(Age.Identity.generate())))
        await other.merge(await index.export())
        #expect(await other.export().secrets["SLACK_BOT_TOKEN"] == before)

        var gone = sealed
        gone.secrets["SLACK_BOT_TOKEN"] = nil
        await index.absorb(gone)
        #expect(await index.export().secrets.isEmpty)
        let file = try String(contentsOfFile: dir + "/scrub-index.json", encoding: .utf8)
        #expect(!file.contains(Self.slack))
    }

    // MARK: - Runs

    private struct Fixture {
        var home: String
        var scrubber: SecretScrubber
        var vault: VaultService
        var transcript: String
        var targets: ScrubTargets
    }

    private func fixture(patterns: ScrubPatterns = .on) async throws -> Fixture {
        let home = NSTemporaryDirectory() + "scrub-\(UUID().uuidString.prefix(8))"
        let kanban = home + "/.kanban-code"
        let vault = VaultService(
            kanbanHome: kanban, keys: MemoryVaultKeyProvider(Age.Identity.generate()), machine: "test", approvals: nil,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil)
        try await vault.store.upsert(VaultSecret(name: "SLACK_BOT_TOKEN", value: Self.slack, tier: .ask))
        let projects = home + "/.claude/projects/-p"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let transcript = projects + "/session.jsonl"
        let lines = [
            #"{"type":"user","message":{"content":"here is the token \#(Self.slack)"}}"#,
            #"{"type":"assistant","message":{"content":"noted"}}"#,
            #"{"type":"user","message":{"content":"and ANTHROPIC_API_KEY=\#(Self.vendor) too"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: transcript))
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: transcript)
        let scrubber = SecretScrubber(vault: vault, home: home, machine: "test")
        await scrubber.setSchedule(ScrubSchedule(patterns: patterns), share: false)
        return Fixture(home: home, scrubber: scrubber, vault: vault, transcript: transcript,
                       targets: ScrubTargets(roots: [home + "/.claude/projects"]))
    }

    private func attributes(_ path: String) throws -> (size: Int, modified: Date, inode: Int) {
        let a = try FileManager.default.attributesOfItem(atPath: path)
        return (a[.size] as! Int, a[.modificationDate] as! Date, (a[.systemFileNumber] as! NSNumber).intValue)
    }

    @Test("a dry run counts and changes nothing")
    func dryRun() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let before = try Data(contentsOf: URL(fileURLWithPath: f.transcript))
        let report = await f.scrubber.run(dryRun: true, targets: f.targets)
        #expect(report.replacements == 2)
        #expect(report.newSecrets == 1)
        #expect(report.filesWithSecrets == 1)
        #expect(report.bySecret["SLACK_BOT_TOKEN"] == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.transcript)) == before)
        #expect(try await f.vault.store.list().count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.home + "/.kanban-code/scrub-backups"))
        let saved = String(decoding: try JSONEncoder.remote.encode(report), as: UTF8.self)
        #expect(!saved.contains(Self.slack) && !saved.contains(Self.vendor))
    }

    @Test("the first run backs up, replaces in place and saves what it found as ask")
    func firstRun() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let before = try attributes(f.transcript)
        let report = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(report.replacements == 2)
        #expect(report.errors.isEmpty)

        let after = try attributes(f.transcript)
        #expect(after.size == before.size)
        #expect(after.inode == before.inode)
        #expect(abs(after.modified.timeIntervalSince(before.modified)) < 0.001)
        let text = try String(contentsOfFile: f.transcript, encoding: .utf8)
        #expect(!text.contains(Self.slack) && !text.contains(Self.vendor))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
        #expect(text.contains("{{vault:SLACK_BOT_TOKEN}}"))

        let found = try await f.vault.store.list(project: "scrubbed")
        #expect(found.count == 1)
        #expect(found.first?.tier == .ask)
        #expect(found.first?.environment == "found")
        let name = try #require(found.first?.name)
        #expect(text.contains("{{vault:\(name)}}"))
        #expect(try await f.vault.store.secret(name)?.value == Self.vendor)

        // The backup holds what was replaced, and puts it back.
        let backup = try #require(report.backupPath)
        #expect(report.backupFiles == 1)
        let ranges = try String(contentsOfFile: backup + "/ranges.jsonl", encoding: .utf8)
        #expect(ranges.split(separator: "\n").count == 2)
        #expect(!ranges.contains(Self.slack))
        #expect(try attributes(backup + "/ranges.jsonl").size < 1024)

        // Nothing to do the second time, and no second backup.
        let again = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(again.replacements == 0)
        #expect(again.filesUnchanged == 1)
        #expect(again.backupPath == nil)
    }

    @Test("restore writes back what a run replaced, and nothing else")
    func restore() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let original = try Data(contentsOf: URL(fileURLWithPath: f.transcript))
        let before = try attributes(f.transcript)
        _ = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.transcript)) != original)

        // A session that goes on appends to the file: the restore leaves that alone.
        let handle = try #require(FileHandle(forWritingAtPath: f.transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"user\"}\n".utf8))
        try handle.close()

        let restored = await f.scrubber.restore(paths: [f.transcript])
        #expect(restored.files == 1 && restored.errors.isEmpty)
        let back = try Data(contentsOf: URL(fileURLWithPath: f.transcript))
        #expect(back.prefix(original.count) == original)
        #expect(back.count == original.count + 16)
        #expect(try attributes(f.transcript).inode == before.inode)
        #expect(await f.scrubber.restore(paths: [f.home + "/other.jsonl"]).errors.count == 1)
    }

    #if canImport(Darwin)
    @Test("a transcript stored compressed on a Mac is compressed again after the run")
    func compressedTranscript() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        // Long enough for transparent compression to apply.
        let filler = String(repeating: #"{"type":"assistant","message":{"content":"nothing to see in this line"}}"# + "\n", count: 4000)
        let handle = try #require(FileHandle(forWritingAtPath: f.transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(filler.utf8))
        try handle.close()
        let packed = f.transcript + ".packed"
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["--hfsCompression", f.transcript, packed])
        ditto.waitUntilExit()
        try FileManager.default.removeItem(atPath: f.transcript)
        try FileManager.default.moveItem(atPath: packed, toPath: f.transcript)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.transcript)
        try #require(ScrubFilePlan.isCompressed(f.transcript))
        let before = try attributes(f.transcript)

        let report = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(report.replacements == 2 && report.errors.isEmpty)
        #expect(ScrubFilePlan.isCompressed(f.transcript))
        let after = try attributes(f.transcript)
        #expect(after.size == before.size)
        #expect(abs(after.modified.timeIntervalSince(before.modified)) < 0.001)
        let text = try String(contentsOfFile: f.transcript, encoding: .utf8)
        #expect(!text.contains(Self.slack) && text.contains("{{vault:SLACK_BOT_TOKEN}}"))
        #expect(!FileManager.default.fileExists(atPath: f.transcript + ".scrub-tmp"))

        // A restore leaves it compressed too.
        _ = await f.scrubber.restore(paths: [f.transcript])
        #expect(ScrubFilePlan.isCompressed(f.transcript))
        #expect(try String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.slack))
    }
    #endif

    @Test("a file written in the last minutes is left for the next run")
    func liveFile() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.transcript)
        let report = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(report.replacements == 0)
        #expect(report.filesLive == 1)
        #expect(report.skipped == 2)
        #expect(try String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.slack))
        #expect(try await f.vault.store.list().count == 1)
    }

    @Test("an extra path of the settings is read, with ~ as this machine's home")
    func extraPaths() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        try FileManager.default.createDirectory(atPath: f.home + "/notes", withIntermediateDirectories: true)
        let log = f.home + "/notes/log.txt"
        try Data("0001 token \(Self.slack) end\n0002 nothing\n".utf8).write(to: URL(fileURLWithPath: log))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: log)

        // Not read until it is listed.
        #expect(!ScrubTargets.standard(home: f.home, kanbanHome: f.home + "/.kanban-code").files().contains { $0.path.hasSuffix("/log.txt") })
        await f.scrubber.setSchedule(ScrubSchedule(paths: [log, " ~/notes/log.txt ", "~/missing"]), share: false)
        #expect(await f.scrubber.schedule().paths == ["~/notes/log.txt", "~/missing"])

        let before = try attributes(log)
        let report = await f.scrubber.run(dryRun: false)
        #expect(report.errors.isEmpty)
        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(!text.contains(Self.slack))
        #expect(text.contains("{{vault:SLACK_BOT_TOKEN}}"))
        #expect(try attributes(log).size == before.size)
        #expect(text.hasSuffix("end\n0002 nothing\n"))
    }

    @Test("settings saved before extra paths existed still load")
    func scheduleWithoutPaths() throws {
        let old = try JSONDecoder().decode(ScrubSchedule.self, from: Data(#"{"enabled":false,"hour":3,"minute":15}"#.utf8))
        #expect(old == ScrubSchedule(enabled: false, hour: 3, minute: 15, paths: []))
    }

    @Test("a real run drops the report of the dry run before it")
    func dryRunReportGoes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        _ = await f.scrubber.run(dryRun: true, targets: f.targets)
        #expect(await f.scrubber.status().lastDryRun != nil)
        _ = await f.scrubber.run(dryRun: false, targets: f.targets)
        let status = await f.scrubber.status()
        #expect(status.lastDryRun == nil)
        #expect(status.lastRun?.replacements == 2)
    }

    @Test("with patterns off only vault values are replaced and nothing is saved")
    func patternsOff() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        await f.scrubber.setSchedule(ScrubSchedule(patterns: .off), share: false)
        let report = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(report.replacements == 1)
        #expect(report.newSecrets == 0)
        let text = try String(contentsOfFile: f.transcript, encoding: .utf8)
        #expect(!text.contains(Self.slack) && text.contains(Self.vendor))
        #expect(try await f.vault.store.list().count == 1)

        // Turned on again, the file is read again.
        await f.scrubber.setSchedule(ScrubSchedule(patterns: .on), share: false)
        let again = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(again.replacements == 1)
        #expect(again.newSecrets == 1)
    }

    static let agentOnly = "sk-ant-" + "api03-Hd1Fy5Gj0UsQm7Xw2Lp9Vt4Zk8Rb3Nc6_Ae-TiOoPqWxYz"

    private func write(_ lines: [String], to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path)
    }

    private func record(_ f: Fixture, _ text: String, card: String = "card_1") throws {
        try write([#"{"at":"2026-01-01T00:00:00Z","text":"\#(text)"}"#], to: f.home + "/.kanban-code/human-messages/\(card).jsonl")
    }

    private func standard(_ f: Fixture) -> ScrubTargets {
        ScrubTargets.standard(home: f.home, kanbanHome: f.home + "/.kanban-code")
    }

    @Test("typed mode takes a key in the record of the human's messages, in every file, and leaves any other")
    func typedMode() async throws {
        let f = try await fixture(patterns: .typed)
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        #expect(ScrubSchedule().patterns == .typed)
        let third = "sk-ant-" + "api03-Zk8Rb3Nc6Hd1Fy5Gj0UsQm7Xw2Lp9Vt4_Ae-TiOoPqWxAb"
        // A user record of a transcript does not count on its own: an agent may have written it.
        let other = f.home + "/.claude/projects/-p/other.jsonl"
        try write([
            #"{"type":"user","message":{"content":"a prompt with \#(Self.agentOnly)"}}"#,
            #"{"type":"assistant","message":{"content":"got \#(Self.vendor) and \#(third) and \#(Self.agentOnly)"}}"#,
        ], to: other)
        try record(f, "use \(Self.vendor) please")
        try write([#"{"at":"2026-01-01T00:00:00.000Z","text":"and \#(third)"}"#], to: f.home + "/.config/rush/sessions/0a1b2c3d/human.jsonl")

        let dry = await f.scrubber.run(dryRun: true, targets: standard(f))
        #expect(dry.newSecrets == 2)
        let report = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(report.newSecrets == 2)
        // The slack token, the key in the fixture transcript, two records, two in the reply.
        #expect(report.replacements == 6)
        let text = try String(contentsOfFile: other, encoding: .utf8)
        #expect(!text.contains(Self.vendor) && !text.contains(third))
        #expect(text.components(separatedBy: Self.agentOnly).count == 3)
        #expect(try !String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.vendor))
        #expect(try !String(contentsOfFile: f.home + "/.config/rush/sessions/0a1b2c3d/human.jsonl", encoding: .utf8).contains(third))
        let names = try await f.vault.store.list().map(\.name)
        #expect(names.count == 3)
        #expect(names.filter { $0.hasPrefix("scrubbed/found/ANTHROPIC_API_KEY_") }.count == 2)
    }

    @Test("typed mode saves nothing from transcripts alone")
    func typedNeedsARecord() async throws {
        let f = try await fixture(patterns: .typed)
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let report = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(report.newSecrets == 0)
        #expect(report.replacements == 1)
        #expect(try String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.vendor))
    }

    @Test("a key typed later is also replaced in files an earlier run left clean")
    func typedLaterReachesCleanFiles() async throws {
        let f = try await fixture(patterns: .typed)
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let first = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(first.newSecrets == 0)
        try record(f, "here it is: \(Self.vendor)")
        let second = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(second.filesUnchanged == 1)
        #expect(second.newSecrets == 1)
        #expect(second.replacements == 2)
        #expect(try !String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.vendor))
        let third = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(third.filesUnchanged == 2)
        #expect(third.replacements == 0)
    }

    static let langwatch = "sk-lw-" + "Qm7Xw2Lp9Vt4Zk8Rb3Nc6Hd1Fy5Gj0UsAeTiOoPqWx"

    @Test("a one-off run takes every vendor key but the excepted ones, and leaves the schedule as it is")
    func oneOffRunWithAnException() async throws {
        let f = try await fixture(patterns: .typed)
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let other = f.home + "/.claude/projects/-p/other.jsonl"
        try write([#"{"type":"assistant","message":{"content":"dev key \#(Self.langwatch) and \#(Self.agentOnly)"}}"#], to: other)
        // The scheduled mode has run and knows the files.
        _ = await f.scrubber.run(dryRun: false, targets: standard(f))
        let once = ScrubOnce(patterns: .on, except: ["LANGWATCH_API_KEY"])

        let dry = await f.scrubber.run(dryRun: true, targets: standard(f), once: once)
        #expect(dry.filesUnchanged == 0)
        #expect(dry.newSecrets == 2)
        #expect(dry.note == "one-off run: patterns on, except LANGWATCH_API_KEY; the schedule is unchanged")
        #expect(dry.bySecret.keys.allSatisfy { $0.hasPrefix("scrubbed/found/ANTHROPIC_API_KEY_") })

        let report = await f.scrubber.run(dryRun: false, targets: standard(f), once: once)
        #expect(report.newSecrets == 2 && report.replacements == 2)
        let text = try String(contentsOfFile: other, encoding: .utf8)
        #expect(text.contains(Self.langwatch) && !text.contains(Self.agentOnly))
        #expect(try !String(contentsOfFile: f.transcript, encoding: .utf8).contains(Self.vendor))
        let names = try await f.vault.store.list().map(\.name)
        #expect(names.filter { $0.hasPrefix("scrubbed/found/ANTHROPIC_API_KEY_") }.count == 2)
        #expect(!names.contains { $0.contains("LANGWATCH") })
        #expect(await f.scrubber.schedule().patterns == .typed)

        let again = await f.scrubber.run(dryRun: true, targets: standard(f), once: once)
        #expect(again.newSecrets == 0 && again.replacements == 0)
        // Without the exception the LangWatch key is taken too.
        let all = await f.scrubber.run(dryRun: true, targets: standard(f), once: ScrubOnce(patterns: .on))
        #expect(all.newSecrets == 1)
        #expect(all.bySecret.keys.allSatisfy { $0.hasPrefix("scrubbed/found/LANGWATCH_API_KEY_") })
        // The scheduled mode still runs as typed and leaves that key.
        let scheduled = await f.scrubber.run(dryRun: false, targets: standard(f))
        #expect(scheduled.note == nil && scheduled.newSecrets == 0)
        #expect(try String(contentsOfFile: other, encoding: .utf8).contains(Self.langwatch))
    }

    @Test("the patterns setting of an older build reads as on or off")
    func oldPatternsSetting() throws {
        func mode(_ json: String) throws -> ScrubPatterns {
            try JSONDecoder().decode(ScrubSchedule.self, from: Data(json.utf8)).patterns
        }
        #expect(try mode(#"{"patterns":true}"#) == .on)
        #expect(try mode(#"{"patterns":false}"#) == .off)
        #expect(try mode(#"{"patterns":"typed"}"#) == .typed)
        #expect(try mode("{}") == .typed)
        #expect(String(decoding: try JSONEncoder().encode(ScrubSchedule(patterns: .on)), as: UTF8.self).contains(#""patterns":"on""#))
    }

    @Test("backups go after a week")
    func backupsExpire() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(atPath: f.home) }
        let root = f.home + "/.kanban-code/scrub-backups"
        for day in ["2026-09-01", "2026-09-28"] {
            try FileManager.default.createDirectory(atPath: root + "/" + day, withIntermediateDirectories: true)
        }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 10, 3, 12)
        let now = try #require(Calendar(identifier: .gregorian).date(from: parts))
        await f.scrubber.purgeBackups(now: now)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["2026-09-28"])
    }

    @Test("the daily time is the next one after now")
    func nextRun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 10, 3, 12, 0)
        let noon = try #require(calendar.date(from: parts))
        let next = try #require(SecretScrubber.nextRun(ScrubSchedule(hour: 4, minute: 30), after: noon, calendar: calendar))
        #expect(calendar.dateComponents([.day, .hour, .minute], from: next) == DateComponents(day: 4, hour: 4, minute: 30))
    }
}
