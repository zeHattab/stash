import Foundation

/// Запись для системного хранилища идентичностей (ASCredentialIdentityStore):
/// домен + логин + id записи. БЕЗ пароля — пароль в систему не уходит.
public struct CredentialIdentityEntry: Sendable, Equatable {
    public let domain: String
    public let user: String
    public let recordID: String
    public init(domain: String, user: String, recordID: String) {
        self.domain = domain; self.user = user; self.recordID = recordID
    }
}

/// Что регистрировать в системном хранилище идентичностей («подсказки над клавиатурой»).
/// Идентичности лежат ВНЕ слотов в открытом виде, поэтому:
/// при выключенной настройке, включённом втором пароле или в ложной сессии — ПУСТО.
public enum CredentialIdentityPlan {
    public static func entries(items: [VaultItem], hintsEnabled: Bool,
                               secondPasswordEnabled: Bool, isDecoySession: Bool) -> [CredentialIdentityEntry] {
        guard hintsEnabled, !secondPasswordEnabled, !isDecoySession else { return [] }
        var out: [CredentialIdentityEntry] = []
        for item in items {
            guard case let .login(username, _, urls, _) = item.kind else { continue }
            let user = username.isEmpty ? item.title : username
            for url in urls {
                guard let host = DomainMatch.host(from: url) else { continue }
                out.append(CredentialIdentityEntry(domain: host, user: user, recordID: item.id.uuidString))
            }
        }
        return out
    }
}
