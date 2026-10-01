import Foundation
@testable import StashCore

struct MockBiometrics: BiometricAuthenticating {
    var biometryType: BiometryKind
    var isAvailable: Bool
    init(type: BiometryKind = .faceID, available: Bool = true) {
        self.biometryType = type
        self.isAvailable = available
    }
}

/// Тестовый Keychain в памяти. @unchecked Sendable — доступ только из тестов (MainActor).
final class MockKeychain: VaultKeyKeychain, @unchecked Sendable {
    var stored: Data?
    /// load вернёт nil, как будто запись пропала (смена биометрии).
    var simulateMissing = false
    /// load бросит ошибку, как будто пользователь отменил биометрию.
    var failOnLoad = false

    func save(_ key: Data) throws { stored = key }
    func load(reason: String) async throws -> Data? {
        if failOnLoad { throw VaultError.ioError("mock cancel") }
        if simulateMissing { return nil }
        return stored
    }
    func deleteKey() throws { stored = nil }
    func hasKey() -> Bool { stored != nil }
}

final class MockSettings: SettingsStore {
    private var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func set(_ value: Int, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func set(_ value: Double, forKey key: String) { values[key] = value }
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.now = date }
}
