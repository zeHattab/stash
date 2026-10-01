import Foundation

/// История паролей логина: при смене пароля сохраняем прежний.
public enum VaultHistory {
    public static let maxEntries = 10

    /// Возвращает `updated` с добавленной записью в историю, если это логин и его
    /// пароль изменился относительно `previous`. Хранит последние `maxEntries`.
    public static func applyingPasswordChange(
        previous: VaultItem?,
        updated: VaultItem,
        now: Date
    ) -> VaultItem {
        guard
            case let .login(_, newPassword, _, _) = updated.kind,
            let previous,
            case let .login(_, oldPassword, _, _) = previous.kind,
            !oldPassword.isEmpty,
            oldPassword != newPassword
        else {
            return updated
        }
        var result = updated
        var history = result.passwordHistory ?? []
        history.insert(PasswordHistoryEntry(password: oldPassword, changedAt: now), at: 0)
        if history.count > maxEntries { history = Array(history.prefix(maxEntries)) }
        result.passwordHistory = history
        return result
    }
}
