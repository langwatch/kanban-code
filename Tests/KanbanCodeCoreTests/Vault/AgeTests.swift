import Foundation
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

@Suite("Age file format")
struct AgeTests {
    @Test func keysRoundTripThroughText() throws {
        let identity = Age.Identity.generate()
        #expect(identity.text.hasPrefix("AGE-SECRET-KEY-1"))
        #expect(try Age.Identity(text: identity.text) == identity)
        #expect(identity.recipient.text.hasPrefix("age1"))
        #expect(try Age.Recipient(text: identity.recipient.text) == identity.recipient)
    }

    @Test func recipientMatchesAgeKeygen() throws {
        guard let keygen = ShellCommand.findExecutable("age-keygen") else { return }
        let identity = Age.Identity.generate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: keygen)
        p.arguments = ["-y"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try p.run()
        stdin.fileHandleForWriting.write(Data((identity.text + "\n").utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == identity.recipient.text)
    }

    @Test(arguments: [0, 1, 100, 64 * 1024 - 1, 64 * 1024, 64 * 1024 + 1, 200_000])
    func roundTrips(size: Int) throws {
        let identity = Age.Identity.generate()
        let plaintext = Data((0..<size).map { UInt8($0 % 251) })
        let file = try Age.encrypt(plaintext, to: [identity.recipient])
        #expect(try Age.decrypt(file, with: identity) == plaintext)
    }

    @Test func anyRecipientCanOpenIt() throws {
        let a = Age.Identity.generate(), b = Age.Identity.generate(), c = Age.Identity.generate()
        let file = try Age.encrypt(Data("hello".utf8), to: [a.recipient, b.recipient])
        #expect(try Age.decrypt(file, with: b) == Data("hello".utf8))
        #expect(throws: Age.AgeError.noMatchingIdentity) { try Age.decrypt(file, with: c) }
    }

    @Test func tamperingIsDetected() throws {
        let identity = Age.Identity.generate()
        var file = try Age.encrypt(Data("secret value".utf8), to: [identity.recipient])
        file[file.count - 3] ^= 0x01
        #expect(throws: Age.AgeError.badPayload) { try Age.decrypt(file, with: identity) }
    }

    @Test func interoperatesWithTheAgeCLI() throws {
        guard let age = ShellCommand.findExecutable("age") else { return }
        let dir = NSTemporaryDirectory() + "age-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let identity = Age.Identity.generate()
        try (identity.text + "\n").write(toFile: dir + "/key.txt", atomically: true, encoding: .utf8)
        let plaintext = Data((0..<150_000).map { UInt8($0 % 13) })

        // Ours -> age
        try Age.encrypt(plaintext, to: [identity.recipient]).write(to: URL(fileURLWithPath: dir + "/ours.age"))
        #expect(run(age, ["-d", "-i", dir + "/key.txt", "-o", dir + "/ours.out", dir + "/ours.age"]) == 0)
        #expect(FileManager.default.contents(atPath: dir + "/ours.out") == plaintext)

        // age -> ours
        try plaintext.write(to: URL(fileURLWithPath: dir + "/plain"))
        #expect(run(age, ["-r", identity.recipient.text, "-o", dir + "/theirs.age", dir + "/plain"]) == 0)
        let theirs = try #require(FileManager.default.contents(atPath: dir + "/theirs.age"))
        #expect(try Age.decrypt(theirs, with: identity) == plaintext)
    }

    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
