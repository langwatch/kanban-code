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
        #expect(content == #"use {{vault:SLACK_BOT_TOKEN}} for "this""#)
        #expect(parsed["n"] as? Int == 1)
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
        #expect(innerParsed["out"] == "{{vault:SLACK_BOT_TOKEN}} and {{vault:DB}}")
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

    private func fixture() async throws -> Fixture {
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

        let backup = try #require(report.backupPath)
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: backup + "/manifest.json")))
        #expect(manifest.values.contains { $0.hasSuffix("/session.jsonl") })
        #expect(report.backupFiles == 1)
        // The copy still holds the file as it was.
        let copy = try #require(manifest.first { $0.value.hasSuffix("/session.jsonl") }?.key)
        if !copy.hasSuffix(".gz") {
            let kept = try String(contentsOfFile: backup + "/" + copy, encoding: .utf8)
            #expect(kept.contains(Self.vendor))
            #expect(kept.utf8.count == text.utf8.count)
        }

        // Nothing to do the second time, and no second backup.
        let again = await f.scrubber.run(dryRun: false, targets: f.targets)
        #expect(again.replacements == 0)
        #expect(again.filesUnchanged == 1)
        #expect(again.backupPath == nil)
    }

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
