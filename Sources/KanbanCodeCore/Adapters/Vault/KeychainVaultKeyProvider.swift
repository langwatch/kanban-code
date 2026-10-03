#if os(macOS)
import Foundation
import KanbanCodeRemoteKit
import Security

/// The vault identity as a generic password in the login keychain. The app
/// that creates the item is the only one macOS lets read it without a
/// prompt (the item's ACL names the app's signature).
public struct KeychainVaultKeyProvider: VaultKeyProvider {
    public let service: String
    public let account: String

    public init(service: String = "io.kanbancode.vault", account: String = "age-identity") {
        self.service = service
        self.account = account
    }

    public func loadIdentity() throws -> Age.Identity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.locked("the keychain refused the vault key (OSStatus \(status))")
        }
        return try Age.Identity(text: String(decoding: data, as: UTF8.self))
    }

    public func saveIdentity(_ identity: Age.Identity) throws {
        let data = Data(identity.text.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Kanban Code vault key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.locked("could not store the vault key in the keychain (OSStatus \(status))")
        }
    }
}
#endif
