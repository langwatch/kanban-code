@_exported import struct KanbanCodeRemoteKit.AttentionRequest
@_exported import struct KanbanCodeRemoteKit.AttentionResolveRequest
@_exported import struct KanbanCodeRemoteKit.AttentionListResponse
@_exported import struct KanbanCodeRemoteKit.MacPresence
@_exported import struct KanbanCodeRemoteKit.VaultApprovalDetails
@_exported import enum KanbanCodeRemoteKit.AttentionCopy
import Foundation

/// The entity is defined in KanbanCodeRemoteKit so the iOS app decodes the
/// same type; Core re-exports it.
extension AttentionRequest {
    /// Options of a vault release request whose lease lasts the maximum.
    public static let vaultApprovalOptions = vaultApprovalOptions(leaseSeconds: VaultLeasePolicy.maximumLease)

    /// Options of a vault release request: the lease option names how
    /// long the card keeps the secret.
    public static func vaultApprovalOptions(leaseSeconds: TimeInterval) -> [String] {
        [vaultLeaseOption(leaseSeconds: leaseSeconds), "Approve once", "Deny"]
    }

    /// "Approve for this card (1 hour)".
    public static func vaultLeaseOption(leaseSeconds: TimeInterval) -> String {
        "\(vaultLeaseOptionPrefix) (\(AttentionCopy.duration(leaseSeconds)))"
    }

    static let vaultLeaseOptionPrefix = "Approve for this card"

    /// Whether `option` is the one that gives the card a lease, whatever its length.
    public static func isVaultLeaseOption(_ option: String) -> Bool {
        option.hasPrefix(vaultLeaseOptionPrefix)
    }
}
