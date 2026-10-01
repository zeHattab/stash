import Foundation

/// Константы формата файла хранилища.
enum VaultFormat {
    static let magic = "stash-vault"
    static let currentVersion = 1
    static let currentSchemaVersion = 1
}

/// Заголовок хранилища. Сохраняется открыто (без шифрования), но целиком
/// используется как authenticated data при шифровании полезной нагрузки —
/// поэтому его подмена ломает расшифровку.
struct VaultHeader: Codable, Sendable, Equatable {
    var formatVersion: Int
    var kdf: KDFParameters
    /// VK, обёрнутый KEK из мастер-пароля.
    var wrappedVaultKey: Data
    // Биометрия (Face ID / Touch ID) реализована через Keychain, а не через
    // отдельное поле в заголовке (см. SECURITY.md). Прежнее поле
    // wrappedVaultKeyBiometric удалено; неизвестные ключи при чтении
    // игнорируются, поэтому старые файлы по-прежнему декодируются.
}

/// То, что физически лежит в файле vault.stash.
/// `header` хранит ТОЧНЫЕ байты заголовка — они же подаются как AAD,
/// чтобы AAD при чтении был байт-в-байт тем же, что при записи.
struct VaultFileOnDisk: Codable, Sendable, Equatable {
    var format: String
    var header: Data
    var ciphertext: Data
}
