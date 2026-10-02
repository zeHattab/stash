import Foundation

/// Стандартные ключи полей документа (стабильные идентификаторы; локализованные
/// подписи — в UI). Значения хранятся в `VaultItemKind.document(fields:)` по rawValue.
public enum DocumentFieldKey: String, Sendable, CaseIterable, Codable {
    case number
    case fullName
    case birthDate
    case issueDate
    case issuer
    case authority
    case series
    case category
    case policyNumber
    case country
}

public enum DocumentFields {
    /// Рекомендуемый набор полей для типа документа.
    public static func recommended(for type: DocumentType) -> [DocumentFieldKey] {
        switch type {
        case .passport:
            return [.number, .fullName, .birthDate, .issueDate, .issuer]
        case .foreignPassport:
            return [.number, .fullName, .birthDate, .issueDate, .authority, .country]
        case .residencePermit:
            return [.number, .fullName, .birthDate, .issueDate, .country]
        case .idCard:
            return [.number, .fullName, .birthDate, .issueDate, .issuer]
        case .driverLicense:
            return [.number, .fullName, .birthDate, .issueDate, .category]
        case .insurance:
            return [.policyNumber, .fullName, .issuer]
        case .certificate:
            return [.number, .fullName, .issueDate, .issuer]
        case .other:
            return [.number, .fullName]
        }
    }
}
