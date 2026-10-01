import Foundation

/// Расшифрованное содержимое сейфа: версия схемы данных + записи.
public struct VaultPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var items: [VaultItem]

    public init(schemaVersion: Int, items: [VaultItem]) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}
