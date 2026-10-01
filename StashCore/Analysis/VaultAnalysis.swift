import Foundation

/// Локальный анализ записей разблокированного сейфа (без сети).
public enum VaultAnalysis {

    /// Пароль записи-логина, или nil.
    public static func password(of item: VaultItem) -> String? {
        if case let .login(_, password, _, _) = item.kind { return password }
        return nil
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
