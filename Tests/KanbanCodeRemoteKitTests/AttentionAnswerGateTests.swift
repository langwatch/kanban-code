import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Answering a request: what the device asks first")
struct AttentionAnswerGateTests {
    private struct MustNotRun: Error {}

    private func request(biometry: Bool, sealed: Bool, aws: Bool = false) -> AttentionRequest {
        var challenge = VaultUnsealChallenge()
        if sealed { challenge.secrets = [.init(name: "PROD", aliases: nil, sealed: "age-ciphertext")] }
        if aws {
            challenge.aws = [.init(profile: "aws:lw-prod", key: .init(name: "AWS_KEY", aliases: nil, sealed: "age-ciphertext"),
                                   role: VaultAwsRole(sourceSecret: "AWS_KEY", roleArn: nil), sessionName: "kanban-card_1")]
        }
        return AttentionRequest(id: "vault_1", cardId: "card_1", kind: .vaultApproval, title: "Card one wants AWS lw-prod access",
                                body: "", options: ["Approve for this card (1 hour)", "Approve once", "Deny"], createdAt: Date(),
                                requiresBiometry: biometry, unseal: challenge.isEmpty ? nil : challenge)
    }

    @Test func denyingNeverAsksForTouchIdOrTheDeviceKey() async throws {
        for subject in [request(biometry: true, sealed: false), request(biometry: true, sealed: true),
                        request(biometry: true, sealed: false, aws: true)] {
            #expect(AttentionAnswerGate.need(for: subject, option: "Deny") == .nothing)
            let passed = try await AttentionAnswerGate.pass(subject, option: "Deny", unlock: { _ in
                Issue.record("the device key was used for a refusal")
                throw MustNotRun()
            }, confirm: {
                Issue.record("Touch ID was asked for a refusal")
                return false
            })
            #expect(passed == .send(nil))
        }
    }

    @Test func approvingASealedSecretOrAnAwsMintUsesTheDeviceKey() async throws {
        let unsealed = VaultUnsealed(values: ["PROD": "v"], device: "abcd")
        for subject in [request(biometry: true, sealed: true), request(biometry: true, sealed: false, aws: true)] {
            for option in ["Approve once", "Approve for this card (1 hour)"] {
                #expect(AttentionAnswerGate.need(for: subject, option: option) == .deviceKey(subject.unseal!))
                let passed = try await AttentionAnswerGate.pass(subject, option: option, unlock: { _ in unsealed }, confirm: {
                    Issue.record("the device key already confirms the owner")
                    return false
                })
                #expect(passed == .send(unsealed))
            }
        }
    }

    @Test func approvingAnyOtherGuardedRequestConfirmsFirst() async throws {
        let subject = request(biometry: true, sealed: false)
        #expect(AttentionAnswerGate.need(for: subject, option: "Approve once") == .confirmation)
        let yes = try await AttentionAnswerGate.pass(subject, option: "Approve once", unlock: { _ in throw MustNotRun() }, confirm: { true })
        #expect(yes == .send(nil))
        let backedOut = try await AttentionAnswerGate.pass(subject, option: "Approve once", unlock: { _ in throw MustNotRun() },
                                                           confirm: { false })
        #expect(backedOut == .cancelled)
    }

    @Test func aRequestThatWantsNoBiometryAsksNothing() {
        let subject = request(biometry: false, sealed: false)
        #expect(AttentionAnswerGate.need(for: subject, option: "Approve once") == .nothing)
        #expect(AttentionAnswerGate.need(for: subject, option: "Deny") == .nothing)
    }

    @Test func aFailedUnlockIsThrownOn() async {
        let subject = request(biometry: true, sealed: true)
        await #expect(throws: MustNotRun.self) {
            _ = try await AttentionAnswerGate.pass(subject, option: "Approve once", unlock: { _ in throw MustNotRun() }, confirm: { true })
        }
    }
}
