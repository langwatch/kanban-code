import AppKit
import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit

/// This Mac as a device of the vault's owner: its Secure Enclave key, the
/// record of the approvals answered here, and answering a request.
enum MacVaultDevice {
    /// The name the audit log gives approvals from this Mac.
    static let deviceName = "mac"

    private static var kanbanHome: String { NSHomeDirectory() + "/.kanban-code" }

    static var key: SecureEnclaveOwnerKey {
        SecureEnclaveOwnerKey(path: VaultService.deviceKeyPath(kanbanHome: kanbanHome))
    }

    static var approvals: VaultDeviceApprovals {
        VaultDeviceApprovals(path: VaultService.deviceApprovalsPath(kanbanHome: kanbanHome))
    }

    /// This Mac's public key as an owner key, when it has one.
    static func recipient() -> VaultOwnerRecipient? {
        key.recipient().map {
            VaultOwnerRecipient(name: Host.current().localizedName ?? "Mac", kind: .mac, publicKey: $0.text)
        }
    }

    enum Answer {
        case sent
        /// The human backed out of Touch ID.
        case cancelled
        case failed(String)
    }

    private struct NoKey: Error {}

    /// Answers `request` from this Mac. An approval that needs the device
    /// key unlocks with it (Touch ID, no password); any other approval
    /// that wants biometry asks for Touch ID or the password first. A
    /// refusal is sent as it is (`AttentionAnswerGate`); with
    /// `noteFollows` the vault holds it for the note the sheet asks for next.
    static func answer(_ request: AttentionRequest, option: String, noteFollows: Bool = false) async -> Answer {
        let unsealed: VaultUnsealed?
        do {
            let passed = try await AttentionAnswerGate.pass(request, option: option, unlock: { challenge in
                guard key.exists else { throw NoKey() }
                return try await key.answer(challenge, reason: "\(option): \(request.title)", sso: ssoCredentials)
            }, confirm: {
                await AppDelegate.confirmWithBiometry(reason: "\(option): \(request.title)")
            })
            guard case .send(let opened) = passed else { return .cancelled }
            unsealed = opened
        } catch is NoKey {
            return .failed("This Mac has no vault key yet. Set it up in Settings > Vault, or answer on the phone.")
        } catch {
            let text = describe(error)
            approvals.record(request, resolution: option, error: text)
            KanbanCodeLog.warn("vault", "Unlocking for \(request.id) on this Mac failed: \(text)")
            if isCancel(error) { return .cancelled }
            // A minting failure already says what to do; "Not unlocked"
            // would point at the device key, which worked.
            return .failed(error is AwsSso.SsoError || error is AwsSts.StsError ? text : "Not unlocked: \(text)")
        }
        if let problem = await AppServices.resolveAttention?(request.id, option, unsealed, noteFollows) {
            if request.kind == .vaultApproval { approvals.record(request, resolution: option, error: problem) }
            return .failed(problem)
        }
        if request.kind == .vaultApproval { approvals.record(request, resolution: option) }
        return .sent
    }

    /// The credentials of a profile of this Mac's `~/.aws/config`, from
    /// its IAM Identity Center sign-in. The sign-in itself (a browser
    /// login) is never started from here.
    static let ssoCredentials: AwsSso.Source = { profile in
        guard let aws = ShellCommand.findExecutable("aws") else { throw AwsSso.SsoError.noCli }
        let environment = ShellCommand.loginEnvironment.filter { !AwsSso.ignoredEnvironment.contains($0.key) }
        let result = try await ShellCommand.run(aws, arguments: AwsSso.exportArguments(profile: profile),
                                                environment: environment, timeout: 30)
        let configPath = environment["AWS_CONFIG_FILE"] ?? NSHomeDirectory() + "/.aws/config"
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        return try AwsSso.credentials(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                                      profile: profile, session: AwsSso.ssoSession(ofProfile: profile, config: config))
    }

    static func isCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        // LAError.userCancel, .appCancel, .systemCancel
        return ns.domain == "com.apple.LocalAuthentication" && [-2, -4, -9].contains(ns.code)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as VaultOwnerSeal.SealError: e.description
        case let e as Age.AgeError: e.description
        case let e as SecureEnclaveOwnerKey.KeyError: e.description
        case let e as AwsSts.StsError: e.description
        case let e as AwsSso.SsoError: e.description
        case let e as VaultError: e.description
        default: error.localizedDescription
        }
    }
}
