import Foundation

/// Облегчённое представление логина для расширения AutoFill (без вложений/истории/заметок).
public struct AutoFillLogin: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let username: String
    public let password: String
    public let urls: [String]
    public let totpSecret: String?

    public init(id: UUID, title: String, username: String, password: String,
                urls: [String], totpSecret: String?) {
        self.id = id; self.title = title; self.username = username
        self.password = password; self.urls = urls; self.totpSecret = totpSecret
    }

    /// Текущий код 2FA, если у записи есть TOTP-секрет.
    public func currentTOTPCode(at date: Date = Date()) -> String? {
        guard let totpSecret, let cfg = OTPAuth.config(fromStored: totpSecret) else { return nil }
        return TOTP.code(cfg, at: date)
    }

    /// Подходит ли запись под сервис-идентификатор запроса автозаполнения.
    public func matches(serviceIdentifier: String) -> Bool {
        DomainMatch.matches(serviceIdentifier: serviceIdentifier, urls: urls)
    }
}
