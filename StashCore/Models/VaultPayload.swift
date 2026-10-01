import Foundation

/// Расшифрованное содержимое сейфа: версия схемы данных + записи.
///
/// Флаги `isDecoy`/`secondPasswordEnabled` — Optional, чтобы старые сейфы
/// (без этих ключей) декодировались; nil трактуется как false. Признак «ложный»
/// живёт ТОЛЬКО здесь, внутри зашифрованного payload, и не виден снаружи.
public struct VaultPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var items: [VaultItem]
    public var isDecoy: Bool?
    public var secondPasswordEnabled: Bool?
    public var recoveryKeySaved: Bool?
    /// В payload НАСТОЯЩЕГО сейфа: ложный сейф почти пуст (мало записей при создании).
    /// Позволяет показать напоминание в настоящем сейфе, не расшифровывая ложный.
    public var decoyNeedsFilling: Bool?
    /// VK и соль ложного сейфа — ТОЛЬКО в payload настоящего сейфа (внутри шифрования).
    /// Позволяют настоящему сейфу управлять ложным (сменить второй пароль), не зная
    /// старого второго пароля. Наружу не видны; в payload ЛОЖНОГО сейфа их нет,
    /// поэтому ложный сейф не даёт доступа к настоящему.
    public var decoyVaultKey: Data?
    public var decoySalt: Data?

    public init(
        schemaVersion: Int,
        items: [VaultItem],
        isDecoy: Bool? = nil,
        secondPasswordEnabled: Bool? = nil,
        recoveryKeySaved: Bool? = nil,
        decoyNeedsFilling: Bool? = nil,
        decoyVaultKey: Data? = nil,
        decoySalt: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.isDecoy = isDecoy
        self.secondPasswordEnabled = secondPasswordEnabled
        self.recoveryKeySaved = recoveryKeySaved
        self.decoyNeedsFilling = decoyNeedsFilling
        self.decoyVaultKey = decoyVaultKey
        self.decoySalt = decoySalt
    }

    public var decoy: Bool { isDecoy ?? false }
    public var secondEnabled: Bool { secondPasswordEnabled ?? false }
    public var recoverySaved: Bool { recoveryKeySaved ?? false }
    public var decoySparse: Bool { decoyNeedsFilling ?? false }
}
