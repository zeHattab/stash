import Foundation
import Security
import LocalAuthentication

/// Хранит Vault Key в Keychain под защитой биометрии.
/// kSecClassGenericPassword + SecAccessControl(.biometryCurrentSet),
/// доступ WhenPasscodeSetThisDeviceOnly, несинхронизируемый.
public struct KeychainVaultKeyStore: VaultKeyKeychain {
    private let service: String
    private let account: String
    /// Группа доступа (общая с расширением AutoFill). nil → группа по умолчанию
    /// из entitlement Keychain Sharing (у нас она единственная, поэтому общая).
    private let accessGroup: String?

    public init(
        service: String = "com.portie24.stash.vaultkey",
        account: String = "vault-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func save(_ key: Data) throws {
        try deleteKey()
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &cfError
        ) else {
            throw VaultError.ioError("SecAccessControl failed")
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: access,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.ioError("Keychain save failed: \(status)")
        }
    }

    public func load(reason: String) async throws -> Data? {
        // Захватываем только Sendable-строки; словарь строим в фоновом потоке.
        let service = self.service
        let account = self.account
        let accessGroup = self.accessGroup
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrSynchronizable as String: false,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context,
                ]
                if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    continuation.resume(returning: result as? Data)
                case errSecItemNotFound:
                    continuation.resume(returning: nil)
                default:
                    continuation.resume(throwing: VaultError.ioError("Keychain load failed: \(status)"))
                }
            }
        }
    }

    public func deleteKey() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.ioError("Keychain delete failed: \(status)")
        }
    }

    public func hasKey() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // Запись есть (errSecSuccess) либо есть, но требует биометрии (errSecInteractionNotAllowed).
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
