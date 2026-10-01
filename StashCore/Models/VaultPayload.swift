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

    public init(
        schemaVersion: Int,
        items: [VaultItem],
        isDecoy: Bool? = nil,
        secondPasswordEnabled: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.isDecoy = isDecoy
        self.secondPasswordEnabled = secondPasswordEnabled
    }

    public var decoy: Bool { isDecoy ?? false }
    public var secondEnabled: Bool { secondPasswordEnabled ?? false }
}
