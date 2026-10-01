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
    /// Записи разблокированного сейфа (в памяти).
    public private(set) var items: [VaultItem] = []
    public private(set) var sortOrder: VaultSortOrder
    public private(set) var generatorOptions: PasswordGeneratorOptions
    public private(set) var lockReason: LockReason = .coldStart
    /// Текущая сессия — ложный сейф. Признак берётся из зашифрованного payload.
    public private(set) var isDecoySession = false
    /// Включён ли «Второй пароль» в текущем сейфе (для текущего payload).
    public private(set) var secondPasswordEnabled = false
    /// Ложный сейф почти пуст (известно настоящему сейфу из своего payload).
    public private(set) var decoyNeedsFilling = false
    /// Ключ восстановления, который нужно показать один раз (после создания/регенерации).
    public private(set) var pendingRecoveryKey: String?
    public private(set) var recoveryKeySaved = false
    public private(set) var masterReminderInterval: ReminderInterval

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
        static let sortOrder = "sortOrder"
        static let generatorOptions = "generatorOptions" // JSON
        static let reminderInterval = "masterReminderInterval"
        static let lastMasterCheck = "lastMasterCheck" // секунды с 1970
        static let installed = "installed"
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
        self.sortOrder = VaultSortOrder(rawValue: settings.string(forKey: Keys.sortOrder) ?? "")
            ?? .title
        if let json = settings.string(forKey: Keys.generatorOptions),
           let data = json.data(using: .utf8),
           let options = try? JSONDecoder().decode(PasswordGeneratorOptions.self, from: data) {
            self.generatorOptions = options
        } else {
            self.generatorOptions = .default
        }
        self.masterReminderInterval = ReminderInterval(rawValue: settings.string(forKey: Keys.reminderInterval) ?? "")
            ?? .days14
    }

    // MARK: - Жизненный цикл

    /// Определяет стартовую фазу: есть файл сейфа → экран блокировки, иначе онбординг.
    public func start() async {
        // Первый запуск после установки: iOS не чистит Keychain при удалении приложения.
        if !settings.bool(forKey: Keys.installed) {
            if !(await store.exists()) {
                disableBiometrics() // удалить возможные остатки ключа Face ID от прежней установки
            }
            settings.set(true, forKey: Keys.installed)
        }
        if await store.exists() {
            phase = .locked
            lockReason = .coldStart
        } else {
            phase = .onboarding
        }
    }

    private func refreshSessionFlags() async {
        isDecoySession = await store.currentIsDecoy()
        secondPasswordEnabled = await store.currentSecondPasswordEnabled()
        recoveryKeySaved = await store.currentRecoveryKeySaved()
        decoyNeedsFilling = await store.currentDecoyNeedsFilling()
    }

    private func recordMasterCheck() {
        settings.set(now().timeIntervalSince1970, forKey: Keys.lastMasterCheck)
    }

    public func isMasterCheckDue() -> Bool {
        guard let days = masterReminderInterval.days else { return false }
        let last = settings.double(forKey: Keys.lastMasterCheck)
        guard last > 0 else { return false }
        return now().timeIntervalSince1970 - last >= Double(days) * 86_400
    }

    public func setMasterReminderInterval(_ interval: ReminderInterval) {
        masterReminderInterval = interval
        settings.set(interval.rawValue, forKey: Keys.reminderInterval)
    }

    // MARK: - Онбординг

    public func createVault(masterPassword: String) async throws {
        let recoveryKey = try await store.create(masterPassword: masterPassword)
        resetFailures()
        recordMasterCheck()
        await reloadItems()
        await refreshSessionFlags()
        pendingRecoveryKey = recoveryKey
        phase = .unlocked
        pendingBiometricOffer = true
    }

    public func dismissBiometricOffer() {
        pendingBiometricOffer = false
    }

    public func dismissRecoveryKey() { pendingRecoveryKey = nil }

    public func markRecoveryKeySaved() async {
        try? await store.setRecoveryKeySaved(true)
        recoveryKeySaved = true
        pendingRecoveryKey = nil
    }

    public func recover(recoveryKey: String, newMasterPassword: String) async throws {
        try await store.recoverWithKey(recoveryKey, newMasterPassword: newMasterPassword)
        resetFailures()
        recordMasterCheck()
        await reloadItems()
        await refreshSessionFlags()
        phase = .unlocked
    }

    @discardableResult
    public func regenerateRecoveryKey(master: String) async throws -> String {
        let key = try await store.regenerateRecoveryKey(masterPassword: master)
        recoveryKeySaved = false
        return key
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
        recordMasterCheck()
        await reloadItems()
        await refreshSessionFlags()
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
        await reloadItems()
        await refreshSessionFlags()
        phase = .unlocked
    }

    public func lock(reason: LockReason = .manual) async {
        await store.lock()
        items = []
        isDecoySession = false
        secondPasswordEnabled = false
        backgroundedAt = nil
        lockReason = reason
        if phase == .unlocked { phase = .locked }
    }

    // MARK: - Записи

    public func reloadItems() async {
        items = (try? await store.items()) ?? []
    }

    /// Сохраняет запись; при смене пароля логина добавляет старый в историю.
    public func save(_ item: VaultItem) async throws {
        let previous = items.first { $0.id == item.id }
        var toSave = item
        toSave.updatedAt = now()
        toSave = VaultHistory.applyingPasswordChange(previous: previous, updated: toSave, now: now())
        try await store.upsert(toSave)
        await reloadItems()
    }

    public func delete(_ id: UUID) async throws {
        try await store.delete(id: id)
        await reloadItems()
    }

    public func toggleFavorite(_ id: UUID) async throws {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        item.updatedAt = now()
        try await store.upsert(item)
        await reloadItems()
    }

    public func setSortOrder(_ order: VaultSortOrder) {
        sortOrder = order
        settings.set(order.rawValue, forKey: Keys.sortOrder)
    }

    public func setGeneratorOptions(_ options: PasswordGeneratorOptions) {
        generatorOptions = options
        if let data = try? JSONEncoder().encode(options),
           let json = String(data: data, encoding: .utf8) {
            settings.set(json, forKey: Keys.generatorOptions)
        }
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

    // MARK: - Второй пароль

    /// Включает второй пароль. decoyItems — записи, которые пользователь собрал на экране
    /// наполнения (без захардкоженных примеров; может быть пусто).
    @discardableResult
    public func enableSecondPassword(_ second: String, decoyItems: [VaultItem] = []) async throws -> String {
        if isDecoySession {
            // Из ложного сейфа: сценарий проходит, но другой слот не трогаем.
            try await store.setSecondPasswordFlag(true)
            secondPasswordEnabled = true
            return ""
        } else {
            let key = try await store.enableSecondVault(secondPassword: second, sampleItems: decoyItems)
            // При включённой функции Face ID не хранит VK — удаляем запись.
            disableBiometrics()
            secondPasswordEnabled = true
            decoyNeedsFilling = await store.currentDecoyNeedsFilling()
            return key
        }
    }

    public func secondPasswordCollides(_ second: String) async -> Bool {
        await store.probeSecondPasswordCollides(second)
    }

    public func changeSecondPassword(master: String, newSecond: String) async throws {
        try await store.changeSecondPassword(master: master, newSecond: newSecond)
    }

    public func disableSecondPassword(master: String) async throws {
        if isDecoySession {
            try await store.setSecondPasswordFlag(false)
            secondPasswordEnabled = false
        } else {
            try await store.disableSecondVault(masterPassword: master)
            secondPasswordEnabled = false
        }
    }

    /// Открыть только что созданный ложный сейф (пароль передаётся из формы).
    public func openDecoy(second: String) async throws {
        try await store.unlock(masterPassword: second)
        resetFailures()
        await reloadItems()
        await refreshSessionFlags()
        phase = .unlocked
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
            await lock(reason: .background)
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
            await lock(reason: .background)
        }
        backgroundedAt = nil
    }

    /// Блокировка при блокировке самого iPhone (protectedDataWillBecomeUnavailable).
    public func deviceDidLock() async {
        guard phase == .unlocked else { return }
        await lock(reason: .deviceLocked)
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
