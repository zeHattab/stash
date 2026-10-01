import Foundation

/// Тип биометрии устройства (для текстов «Face ID» / «Touch ID»).
public enum BiometryKind: String, Sendable, Equatable {
    case none
    case faceID
    case touchID
}

/// Доступность и тип биометрии. Реальная реализация — поверх LocalAuthentication,
/// в тестах подменяется моком.
public protocol BiometricAuthenticating: Sendable {
    var biometryType: BiometryKind { get }
    /// Биометрия доступна и на устройстве установлен код-пароль.
    var isAvailable: Bool { get }
}

/// Хранилище Vault Key в Keychain под защитой биометрии.
/// `load` в реальной реализации показывает запрос Face ID/Touch ID.
public protocol VaultKeyKeychain: Sendable {
    func save(_ key: Data) throws
    /// Возвращает ключ (с биометрическим запросом) или nil, если записи нет
    /// (в т.ч. если набор биометрии изменился и запись аннулирована).
    func load(reason: String) async throws -> Data?
    func deleteKey() throws
    func hasKey() -> Bool
}

/// Простое key-value хранилище настроек (реально — UserDefaults в App Group).
public protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func integer(forKey key: String) -> Int
    func set(_ value: Int, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
}

/// Таймаут автоблокировки.
public enum AutoLockTimeout: String, CaseIterable, Sendable, Codable {
    case immediately
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    public var seconds: TimeInterval {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        }
    }
}

/// Как часто просить ввести мастер-пароль вместо Face ID (проверка памяти).
public enum ReminderInterval: String, CaseIterable, Sendable, Codable {
    case days7, days14, days30, never
    public var days: Int? {
        switch self {
        case .days7: return 7
        case .days14: return 14
        case .days30: return 30
        case .never: return nil
        }
    }
}

/// Почему сейф заблокирован — от этого зависит, запрашивать ли Face ID автоматически.
public enum LockReason: Sendable, Equatable {
    case manual        // пользователь нажал «Заблокировать» — Face ID НЕ запрашивать автоматически
    case background    // ушли в фон дольше таймера
    case deviceLocked  // заблокировали сам iPhone
    case coldStart     // первый запуск
}

/// Порядок сортировки списка записей (выбор запоминается).
public enum VaultSortOrder: String, CaseIterable, Sendable, Codable {
    case title
    case dateModified
}

/// Ошибки прикладного слоя (поверх VaultError).
public enum AppModelError: Error, Equatable, Sendable {
    case lockedOut(remaining: TimeInterval)
    case biometricsUnavailable
    case biometricKeyMissing
    case noVault
}
