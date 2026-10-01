import Foundation
import Observation
import CryptoKit

/// Состояние приложения и вся логика онбординга/блокировки/настроек.
/// View только отображает и вызывает методы — поэтому логику можно тестировать.
@MainActor
@Observable
public final class AppModel {

    public enum Phase: Equatable, Sendable {
        case onboarding
        case locked
        case unlocked
    }

    // MARK: - Наблюдаемое состояние
    public private(set) var phase: Phase = .onboarding
    public private(set) var isBiometricEnabled: Bool
    public private(set) var autoLockTimeout: AutoLockTimeout
    public private(set) var failedAttempts: Int
    public private(set) var lockedOutUntil: Date?
    /// Показать одноразовое предложение включить Face ID (сразу после создания сейфа).
    public private(set) var pendingBiometricOffer: Bool = false

    public var biometryType: BiometryKind { biometrics.biometryType }
    public var isBiometricAvailable: Bool { biometrics.isAvailable }

    // MARK: - Зависимости
    private let store: VaultStore
    private let biometrics: any BiometricAuthenticating
    private let keychain: any VaultKeyKeychain
    private let settings: any SettingsStore
    private let now: () -> Date

    private var backgroundedAt: Date?

    private enum Keys {
        static let biometricEnabled = "biometricEnabled"
        static let autoLock = "autoLockTimeout"
        static let failedAttempts = "failedAttempts"
        static let lockedOutUntil = "lockedOutUntil" // секунды с 1970; 0 = нет
    }

    // Нарастающая пауза после 5 ошибок подряд: 30 c, 1 мин, далее 5 мин.
    private static let lockoutSteps: [TimeInterval] = [30, 60, 300]
    private static let attemptsBeforeLockout = 5

    public init(
        store: VaultStore,
        biometrics: any BiometricAuthenticating,
        keychain: any VaultKeyKeychain,
        settings: any SettingsStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.biometrics = biometrics
        self.keychain = keychain
        self.settings = settings
        self.now = now

        self.isBiometricEnabled = settings.bool(forKey: Keys.biometricEnabled)
        self.autoLockTimeout = AutoLockTimeout(rawValue: settings.string(forKey: Keys.autoLock) ?? "")
            ?? .oneMinute
        self.failedAttempts = settings.integer(forKey: Keys.failedAttempts)
        let until = settings.double(forKey: Keys.lockedOutUntil)
        self.lockedOutUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
    }

    // MARK: - Жизненный цикл

    /// Определяет стартовую фазу: есть файл сейфа → экран блокировки, иначе онбординг.
    public func start() async {
        phase = await store.exists() ? .locked : .onboarding
    }

    // MARK: - Онбординг

    public func createVault(masterPassword: String) async throws {
        try await store.create(masterPassword: masterPassword)
        resetFailures()
        phase = .unlocked
        pendingBiometricOffer = true
    }

    public func dismissBiometricOffer() {
        pendingBiometricOffer = false
    }

    // MARK: - Биометрия

    public func enableBiometrics() async throws {
        guard biometrics.isAvailable else { throw AppModelError.biometricsUnavailable }
        let vaultKey = try await store.exportVaultKey()
        var data = vaultKey.withUnsafeBytes { Data($0) }
        defer { data.resetBytes(in: 0..<data.count) }
        try keychain.save(data)
        isBiometricEnabled = true
        pendingBiometricOffer = false
        settings.set(true, forKey: Keys.biometricEnabled)
    }

    public func disableBiometrics() {
        try? keychain.deleteKey()
        isBiometricEnabled = false
        settings.set(false, forKey: Keys.biometricEnabled)
    }

    // MARK: - Разблокировка

    public func unlockWithPassword(_ password: String) async throws {
        if let until = lockedOutUntil, now() < until {
            throw AppModelError.lockedOut(remaining: until.timeIntervalSince(now()))
        }
        do {
            try await store.unlock(masterPassword: password)
        } catch VaultError.wrongPassword {
            registerFailure()
            throw VaultError.wrongPassword
        }
        resetFailures()
        phase = .unlocked
    }

    public func unlockWithBiometrics() async throws {
        guard isBiometricEnabled, keychain.hasKey() else {
            throw AppModelError.biometricKeyMissing
        }
        var data: Data
        do {
            guard let loaded = try await keychain.load(reason: biometricReason()) else {
                // Записи нет (в т.ч. набор биометрии изменился) → откат на пароль.
                invalidateBiometrics()
                throw AppModelError.biometricKeyMissing
            }
            data = loaded
        }
        defer { data.resetBytes(in: 0..<data.count) }

        let vaultKey = SymmetricKey(data: data)
        do {
            try await store.unlock(vaultKey: vaultKey)
        } catch {
            // VK не подошёл (устарел) → удалить запись, попросить мастер-пароль.
            invalidateBiometrics()
            throw error
        }
        resetFailures()
        phase = .unlocked
    }

    public func lock() async {
        await store.lock()
        backgroundedAt = nil
        if phase == .unlocked { phase = .locked }
    }

    // MARK: - Смена мастер-пароля

    public func changeMasterPassword(old: String, new: String) async throws {
        try await store.changeMasterPassword(old: old, new: new)
        // VK не меняется, но если включён Face ID — пере-сохраняем на всякий случай.
        if isBiometricEnabled {
            if let vaultKey = try? await store.exportVaultKey() {
                var data = vaultKey.withUnsafeBytes { Data($0) }
                defer { data.resetBytes(in: 0..<data.count) }
                try? keychain.save(data)
            }
        }
    }

    // MARK: - Автоблокировка

    public func setAutoLockTimeout(_ timeout: AutoLockTimeout) {
        autoLockTimeout = timeout
        settings.set(timeout.rawValue, forKey: Keys.autoLock)
    }

    /// Уход в фон. При таймауте «сразу» блокируем немедленно, иначе запоминаем время.
    public func didEnterBackground(at date: Date) async {
        guard phase == .unlocked else { return }
        if autoLockTimeout == .immediately {
            await lock()
        } else {
            backgroundedAt = date
        }
    }

    /// Возврат на передний план. Блокируем, если прошло >= таймаута (по времени, не по таймерам).
    public func willEnterForeground(at date: Date) async {
        guard phase == .unlocked, let since = backgroundedAt else {
            backgroundedAt = nil
            return
        }
        if date.timeIntervalSince(since) >= autoLockTimeout.seconds {
            await lock()
        }
        backgroundedAt = nil
    }

    // MARK: - Внутреннее

    private func biometricReason() -> String {
        String(localized: "Разблокировать Stash")
    }

    private func invalidateBiometrics() {
        try? keychain.deleteKey()
        isBiometricEnabled = false
        settings.set(false, forKey: Keys.biometricEnabled)
    }

    private func registerFailure() {
        failedAttempts += 1
        settings.set(failedAttempts, forKey: Keys.failedAttempts)
        if failedAttempts >= Self.attemptsBeforeLockout {
            let index = min(failedAttempts - Self.attemptsBeforeLockout, Self.lockoutSteps.count - 1)
            let until = now().addingTimeInterval(Self.lockoutSteps[index])
            lockedOutUntil = until
            settings.set(until.timeIntervalSince1970, forKey: Keys.lockedOutUntil)
        }
    }

    private func resetFailures() {
        failedAttempts = 0
        lockedOutUntil = nil
        settings.set(0, forKey: Keys.failedAttempts)
        settings.set(0, forKey: Keys.lockedOutUntil)
    }
}
