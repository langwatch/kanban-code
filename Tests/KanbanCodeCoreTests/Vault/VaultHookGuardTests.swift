import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("The vault hook's secret guard")
struct VaultHookGuardTests {
    /// Runs the hook as Claude Code does, in a folder with no .env.vault,
    /// and returns what it printed.
    private func run(_ command: String) throws -> String {
        let dir = NSTemporaryDirectory() + "vault-guard-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let script = dir + "/vault-hook.sh"
        try VaultHook.scriptContent.write(toFile: script, atomically: true, encoding: .utf8)
        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": command],
        ])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: out, as: UTF8.self)
    }

    @Test("refuses reading a .env under /etc, loading one to list the environment, and dumping an environment", arguments: [
        "systemd-run -p EnvironmentFile=/etc/laze/prod.env sh -c 'env | cut -d= -f1 | grep pg'",
        "systemd-run --pipe --wait -p EnvironmentFile=/etc/laze/prod.env /bin/sh -c 'printenv'",
        "docker run --rm --env-file /etc/laze/prod.env alpine env",
        "cat /etc/laze/prod.env",
        "grep -i PG /etc/laze/prod.env",
        "sudo sed -n 1,5p /etc/laze/prod.env",
        "awk -F= '{print $1}' /etc/laze/prod.env",
        "tail -n 3 \"/etc/laze/dev.env\"",
        "less /etc/foo/bar.env",
        "sudo -u laze cat /etc/laze/prod.env",
        "cp /etc/laze/prod.env /tmp/x",
        ". /etc/laze/prod.env && echo ok",
        "set -a; source /etc/laze/prod.env; set +a; ./run.sh",
        "while read l; do echo \"$l\"; done < /etc/laze/prod.env",
        "cd /srv && head /etc/laze/*.env",
        "env",
        "env | sort",
        "env | cut -d= -f1",
        "printenv | grep -i key",
        "export -p",
        "declare -x",
        "set | head",
        "cat /proc/1/environ | tr '\\0' '\\n'",
        "ls\nenv\n",
    ])
    func refuses(command: String) throws {
        let out = try run(command)
        #expect(out.contains("\"permissionDecision\":\"deny\""), "not refused: \(command)")
        #expect(out.contains("kv env --names"))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        #expect(parsed?["hookSpecificOutput"] != nil)
    }

    @Test("lets ordinary commands, systemctl, kv env --names and mentions of the path through", arguments: [
        "systemctl restart laze-api",
        "systemctl cat laze-api && systemctl status laze-worker --no-pager",
        "kv env --names /etc/laze/prod.env",
        "kv env .env.vault -- pnpm dev",
        "git commit -m \"fix: stop reading /etc/laze/prod.env in deploy\"",
        "ls -la /etc/laze/",
        "echo $HOME",
        "env FOO=1 make test",
        "printenv HOME",
        "cat .env.example",
        "grep -r token src/",
        "set -euo pipefail; make",
        "export FOO=bar && ./run.sh",
        "systemd-run -p EnvironmentFile=/etc/laze/prod.env /usr/bin/laze-tasks migrate",
        "docker compose --env-file /etc/laze/prod.env up -d",
        "rg -n 'EnvironmentFile' Scripts/",
    ])
    func allows(command: String) throws {
        #expect(try run(command).isEmpty, "refused: \(command)")
    }
}
