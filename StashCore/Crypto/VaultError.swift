import Foundation

/// Ошибки хранилища Stash. Неверный пароль и порча данных различаются намеренно.
public enum VaultError: Error, Equatable, Sendable {
    /// Мастер-пароль не подошёл (не удалось развернуть Vault Key).
    case wrongPassword
    /// Данные не прошли проверку подлинности (повреждены или подменены).
    case corrupted
    /// Версия формата файла не поддерживается этой сборкой.
    case unsupportedVersion(Int)
    /// Ошибка ввода-вывода или системного примитива.
    case ioError(String)
    /// Операция требует разблокированного хранилища.
    case locked
    /// Попытка создать хранилище поверх уже существующего файла.
    case alreadyExists
    /// Файл хранилища отсутствует.
    case notFound
}
