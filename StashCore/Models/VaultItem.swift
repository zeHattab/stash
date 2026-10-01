import Foundation

/// Тип документа для записи `document`.
public enum DocumentType: String, Codable, Sendable, Equatable {
    case passport
    case residencePermit
    case driverLicense
    case insurance
    case other
}

/// Содержимое записи. Enum с ассоциированными данными; Codable синтезируется
/// автоматически (Swift ≥ 5.5).
public enum VaultItemKind: Codable, Sendable, Equatable {
    case login(username: String, password: String, urls: [String], totpSecret: String?)
    case secureNote
    case document(type: DocumentType, fields: [String: String], expiresAt: Date?, attachmentIDs: [UUID])
}

/// Одна запись в истории паролей логина.
public struct PasswordHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var password: String
    public var changedAt: Date

    public init(id: UUID = UUID(), password: String, changedAt: Date) {
        self.id = id
        self.password = password
        self.changedAt = changedAt
    }
}

/// Единица хранения в сейфе.
public struct VaultItem: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: VaultItemKind
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var favorite: Bool
    public var notes: String
    /// История прежних паролей (для логинов). Optional → старые сейфы без этого
    /// ключа декодируются (synthesized Codable для Optional использует decodeIfPresent).
    public var passwordHistory: [PasswordHistoryEntry]?

    public init(
        id: UUID = UUID(),
        kind: VaultItemKind,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        favorite: Bool = false,
        notes: String = "",
        passwordHistory: [PasswordHistoryEntry]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.favorite = favorite
        self.notes = notes
        self.passwordHistory = passwordHistory
    }
}
