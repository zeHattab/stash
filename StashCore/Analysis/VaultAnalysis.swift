import Foundation

/// Локальный анализ записей разблокированного сейфа (без сети).
public enum VaultAnalysis {

    /// Пароль записи-логина, или nil.
    public static func password(of item: VaultItem) -> String? {
        if case let .login(_, password, _, _) = item.kind { return password }
        return nil
    }

    /// Срок действия документа (или nil).
    public static func expiryDate(of item: VaultItem) -> Date? {
        if case let .document(_, _, expiresAt, _) = item.kind { return expiresAt }
        return nil
    }

    /// Документы, срок которых истекает в ближайшие `days` дней (а также уже истёкшие),
    /// по возрастанию даты.
    public static func soonExpiring(_ items: [VaultItem], within days: Int, now: Date) -> [VaultItem] {
        let limit = now.addingTimeInterval(Double(days) * 86_400)
        return items
            .compactMap { item -> (VaultItem, Date)? in
                guard let e = expiryDate(of: item), e <= limit else { return nil }
                return (item, e)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Сколько ДРУГИХ записей используют тот же пароль (пустые пароли не считаются).
    public static func reuseCount(ofItemID id: UUID, in items: [VaultItem]) -> Int {
        guard let target = items.first(where: { $0.id == id }),
              let pw = password(of: target), !pw.isEmpty else { return 0 }
        return items.reduce(0) { count, item in
            guard item.id != id, let other = password(of: item), other == pw else { return count }
            return count + 1
        }
    }
}
