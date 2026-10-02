import Foundation

/// Тип документа для записи `document`.
public enum DocumentType: String, Codable, Sendable, Equatable, CaseIterable {
    case passport            // паспорт
    case foreignPassport     // загранпаспорт
    case residencePermit     // ВНЖ
    case idCard              // ID-карта
    case driverLicense       // водительские права
    case insurance           // страховка
    case certificate         // свидетельство
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

/// Вложение документа (скан/фото или PDF). Байты хранятся ВНУТРИ слота (в payload),
/// никаких отдельных файлов вне контейнера (требование SECURITY.md).
public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, Equatable { case image, pdf }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var data: Data

    public init(id: UUID = UUID(), name: String, kind: Kind, data: Data) {
        self.id = id; self.name = name; self.kind = kind; self.data = data
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
    /// Вложения документа (optional для обратной совместимости).
    public var attachments: [Attachment]?

    public init(
        id: UUID = UUID(),
        kind: VaultItemKind,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        favorite: Bool = false,
        notes: String = "",
        passwordHistory: [PasswordHistoryEntry]? = nil,
        attachments: [Attachment]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.favorite = favorite
        self.notes = notes
        self.passwordHistory = passwordHistory
        self.attachments = attachments
    }
}
