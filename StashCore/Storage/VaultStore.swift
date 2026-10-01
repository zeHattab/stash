import Foundation
import CryptoKit

/// Хранилище. Контейнер v3 (см. VaultContainerV3): два равных слота без открытых
/// полей. В каждом слоте VK обёрнут ДВАЖДЫ — мастер-паролем и ключом восстановления;
/// обе обёртки неотличимы от случайных байтов. Второй пароль (ложный сейф) — отдельный
/// слот со своими обёртками.
public actor VaultStore {

    public struct Configuration: Sendable {
        public var fileURL: URL
        public var kdfIterations: UInt32
        public init(fileURL: URL, kdfIterations: UInt32 = 600_000) {
            self.fileURL = fileURL
            self.kdfIterations = kdfIterations
        }
    }

    private let config: Configuration

    private var vaultKey: SymmetricKey?
    private var cachedItems: [VaultItem]?
    private var openedSlot: Int?
    private var currentSalt: Data?
    private var currentWrapMaster: Data?
    private var currentWrapRecovery: Data?
    private var otherSlotBytes: Data?
    private var slotSize = VaultContainerV3.defaultSlotSize
    private var kdfIterations: UInt32
    private var isDecoyFlag = false
    private var secondEnabledFlag = false
    private var recoverySavedFlag = false

    public init(configuration: Configuration) {
        self.config = configuration
        self.kdfIterations = configuration.kdfIterations
    }

    // MARK: - Состояние

    public var isUnlocked: Bool { vaultKey != nil }
    public func currentIsDecoy() -> Bool { isDecoyFlag }
    public func currentSecondPasswordEnabled() -> Bool { secondEnabledFlag }
    public func currentRecoveryKeySaved() -> Bool { recoverySavedFlag }
    func openedSlotForTesting() -> Int? { openedSlot }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: config.fileURL.path)
    }

    // MARK: - Создание

    /// Создаёт сейф и возвращает ключ восстановления (показать пользователю один раз).
    @discardableResult
    public func create(masterPassword: String) throws -> String {
        guard !exists() else { throw VaultError.alreadyExists }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let vk = SymmetricKey(size: .bits256)
        let salt = try Random.bytes(16)
        let recoveryKey = try RecoveryKey.generate()
        let wrapMaster = try wrap(vk, credential: password, salt: salt)
        let wrapRecovery = try wrap(vk, credential: RecoveryKey.keyData(recoveryKey), salt: salt)
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: [],
                                   isDecoy: false, secondPasswordEnabled: false, recoveryKeySaved: false)
        try installFreshV3(vk: vk, salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery, payload: payload)
        return recoveryKey
    }

    // MARK: - Разблокировка

    public func unlock(masterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let data = try readFile()
        if VaultContainerV3.isV3(data) {
            try openV3(data: data, credential: password)
        } else if VaultContainer.isV2(data) {
            try migrateV2(data: data, password: password)
        } else {
            try migrateV1(data: data, password: password)
        }
    }

    /// Разблокировка готовым VK (Face ID). Работает, только когда второй пароль выключен.
    public func unlock(vaultKey vk: SymmetricKey) throws {
        guard exists() else { throw VaultError.notFound }
        let data = try readFile()
        guard VaultContainerV3.isV3(data) else { throw VaultError.corrupted }
        let container = try VaultContainerV3.parse(data)
        kdfIterations = container.iterations
        slotSize = container.slotSize
        for index in 0..<2 {
            let s = VaultContainerV3.parseSlot(container.slots[index])
            guard let payload = try? decryptPayload(ciphertext: s.ciphertext, vk: vk, salt: s.salt) else { continue }
            setOpened(index: index, slot: s, vk: vk, payload: payload, container: container)
            return
        }
        throw VaultError.corrupted
    }

    /// «Забыли пароль»: ключ восстановления открывает сейф и задаёт новый мастер-пароль.
    public func recoverWithKey(_ recoveryKey: String, newMasterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        let data = try readFile()
        guard VaultContainerV3.isV3(data) else { throw VaultError.corrupted }
        let container = try VaultContainerV3.parse(data)
        kdfIterations = container.iterations
        slotSize = container.slotSize

        var keyData = RecoveryKey.keyData(recoveryKey)
        var newPw = Data(newMasterPassword.utf8)
        defer { keyData.resetBytes(in: 0..<keyData.count); newPw.resetBytes(in: 0..<newPw.count) }

        let s0 = VaultContainerV3.parseSlot(container.slots[0])
        let s1 = VaultContainerV3.parseSlot(container.slots[1])
        let kek0 = try KDF.derive(password: keyData, parameters: params(s0.salt))
        let kek1 = try KDF.derive(password: keyData, parameters: params(s1.salt))

        for (index, s, kek) in [(0, s0, kek0), (1, s1, kek1)] {
            guard let vk = try? Crypto.unwrap(s.wrapRecovery, with: kek),
                  let payload = try? decryptPayload(ciphertext: s.ciphertext, vk: vk, salt: s.salt) else { continue }
            // Пере-обёртка мастер-ключа новым паролем (соль та же), восстановление оставляем.
            let newWrapMaster = try wrap(vk, credential: newPw, salt: s.salt)
            setOpened(index: index, slot: s, vk: vk, payload: payload, container: container)
            currentWrapMaster = newWrapMaster
            try persistCurrent()
            return
        }
        throw VaultError.wrongPassword
    }

    // MARK: - Ключ восстановления

    /// Создаёт новый ключ восстановления (старый перестаёт работать). Требует мастер-пароль.
    public func regenerateRecoveryKey(masterPassword: String) throws -> String {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster, isUnlocked else {
            throw VaultError.locked
        }
        var pw = Data(masterPassword.utf8); defer { pw.resetBytes(in: 0..<pw.count) }
        let kek = try KDF.derive(password: pw, parameters: params(salt))
        guard (try? Crypto.unwrap(wrapMaster, with: kek)) != nil else { throw VaultError.wrongPassword }

        let newKey = try RecoveryKey.generate()
        currentWrapRecovery = try wrap(vk, credential: RecoveryKey.keyData(newKey), salt: salt)
        recoverySavedFlag = false
        try persistCurrent()
        return newKey
    }

    public func setRecoveryKeySaved(_ saved: Bool) throws {
        guard isUnlocked else { throw VaultError.locked }
        recoverySavedFlag = saved
        try persistCurrent()
    }

    public func exportVaultKey() throws -> SymmetricKey {
        guard let vk = vaultKey, isUnlocked else { throw VaultError.locked }
        return vk
    }

    public func lock() {
        vaultKey = nil; cachedItems = nil; openedSlot = nil
        currentSalt = nil; currentWrapMaster = nil; currentWrapRecovery = nil
        otherSlotBytes = nil; isDecoyFlag = false; secondEnabledFlag = false; recoverySavedFlag = false
    }

    // MARK: - Записи

    public func items() throws -> [VaultItem] {
        guard let items = cachedItems, isUnlocked else { throw VaultError.locked }
        return items
    }

    public func upsert(_ item: VaultItem) throws {
        guard var items = cachedItems, isUnlocked else { throw VaultError.locked }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        cachedItems = items
        try persistCurrent()
    }

    public func delete(id: UUID) throws {
        guard var items = cachedItems, isUnlocked else { throw VaultError.locked }
        items.removeAll { $0.id == id }
        cachedItems = items
        try persistCurrent()
    }

    public func changeMasterPassword(old: String, new: String) throws {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster, isUnlocked else {
            throw VaultError.locked
        }
        var oldPw = Data(old.utf8); var newPw = Data(new.utf8)
        defer { oldPw.resetBytes(in: 0..<oldPw.count); newPw.resetBytes(in: 0..<newPw.count) }
        let oldKek = try KDF.derive(password: oldPw, parameters: params(salt))
        guard (try? Crypto.unwrap(wrapMaster, with: oldKek)) != nil else { throw VaultError.wrongPassword }
        currentWrapMaster = try wrap(vk, credential: newPw, salt: salt)
        try persistCurrent()
    }

    // MARK: - Второй пароль

    /// Включает ложный сейф в свободном слоте и возвращает его ключ восстановления.
    @discardableResult
    public func enableSecondVault(secondPassword: String, sampleItems: [VaultItem]) throws -> String {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster,
              let wrapRecovery = currentWrapRecovery, let slotIndex = openedSlot, isUnlocked else {
            throw VaultError.locked
        }
        guard !isDecoyFlag else { return "" }
        var second = Data(secondPassword.utf8); defer { second.resetBytes(in: 0..<second.count) }
        let probe = try KDF.derive(password: second, parameters: params(salt))
        if (try? Crypto.unwrap(wrapMaster, with: probe)) != nil
            || (try? Crypto.unwrap(wrapRecovery, with: probe)) != nil {
            throw VaultError.secondPasswordMustDiffer
        }

        let vk2 = SymmetricKey(size: .bits256)
        let salt2 = try Random.bytes(16)
        let decoyRecovery = try RecoveryKey.generate()
        let wrapM2 = try wrap(vk2, credential: second, salt: salt2)
        let wrapR2 = try wrap(vk2, credential: RecoveryKey.keyData(decoyRecovery), salt: salt2)
        let decoyPayload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: sampleItems,
                                        isDecoy: true, secondPasswordEnabled: false, recoveryKeySaved: false)
        let ct2 = try encryptPayload(decoyPayload, vk: vk2, salt: salt2)
        let decoySlot = try VaultContainerV3.buildSlot(salt: salt2, wrapMaster: wrapM2, wrapRecovery: wrapR2,
                                                       payloadCiphertext: ct2, slotSize: slotSize)

        secondEnabledFlag = true
        otherSlotBytes = decoySlot
        try persistCurrent() // перезаписывает текущий слот (флаг) + кладёт decoySlot в другой
        _ = slotIndex
        return decoyRecovery
    }

    public func disableSecondVault(masterPassword: String) throws {
        guard let salt = currentSalt, let wrapMaster = currentWrapMaster, isUnlocked else { throw VaultError.locked }
        guard !isDecoyFlag else { return }
        var pw = Data(masterPassword.utf8); defer { pw.resetBytes(in: 0..<pw.count) }
        let kek = try KDF.derive(password: pw, parameters: params(salt))
        guard (try? Crypto.unwrap(wrapMaster, with: kek)) != nil else { throw VaultError.wrongPassword }
        otherSlotBytes = try Random.bytes(slotSize)
        secondEnabledFlag = false
        try persistCurrent()
    }

    public func setSecondPasswordFlag(_ enabled: Bool) throws {
        guard isUnlocked else { throw VaultError.locked }
        secondEnabledFlag = enabled
        try persistCurrent()
    }

    // MARK: - Внутреннее

    private func openV3(data: Data, credential: Data) throws {
        let container = try VaultContainerV3.parse(data)
        kdfIterations = container.iterations
        slotSize = container.slotSize
        let s0 = VaultContainerV3.parseSlot(container.slots[0])
        let s1 = VaultContainerV3.parseSlot(container.slots[1])
        // KDF по обеим солям выполняется всегда (симметрия по времени).
        let kek0 = try KDF.derive(password: credential, parameters: params(s0.salt))
        let kek1 = try KDF.derive(password: credential, parameters: params(s1.salt))

        var sawCorrupted = false
        for (index, s, kek) in [(0, s0, kek0), (1, s1, kek1)] {
            let vk = (try? Crypto.unwrap(s.wrapMaster, with: kek)) ?? (try? Crypto.unwrap(s.wrapRecovery, with: kek))
            guard let vk else { continue }
            guard let payload = try? decryptPayload(ciphertext: s.ciphertext, vk: vk, salt: s.salt) else {
                sawCorrupted = true; continue
            }
            setOpened(index: index, slot: s, vk: vk, payload: payload, container: container)
            return
        }
        throw sawCorrupted ? VaultError.corrupted : VaultError.wrongPassword
    }

    private func setOpened(index: Int,
                           slot s: (salt: Data, wrapMaster: Data, wrapRecovery: Data, ciphertext: Data),
                           vk: SymmetricKey, payload: VaultPayload, container: VaultContainerV3.Container) {
        openedSlot = index
        currentSalt = s.salt
        currentWrapMaster = s.wrapMaster
        currentWrapRecovery = s.wrapRecovery
        otherSlotBytes = container.slots[1 - index]
        vaultKey = vk
        cachedItems = payload.items
        isDecoyFlag = payload.decoy
        secondEnabledFlag = payload.secondEnabled
        recoverySavedFlag = payload.recoverySaved
    }

    private func installFreshV3(vk: SymmetricKey, salt: Data, wrapMaster: Data, wrapRecovery: Data, payload: VaultPayload) throws {
        slotSize = VaultContainerV3.defaultSlotSize
        let ct = try encryptPayload(payload, vk: vk, salt: salt)
        let realSlot = try VaultContainerV3.buildSlot(salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                                                      payloadCiphertext: ct, slotSize: slotSize)
        let otherSlot = try Random.bytes(slotSize)
        let realIndex = try randomBit()
        try writeContainer(current: realSlot, currentIndex: realIndex, other: otherSlot)
        openedSlot = realIndex
        otherSlotBytes = otherSlot
        currentSalt = salt
        currentWrapMaster = wrapMaster
        currentWrapRecovery = wrapRecovery
        vaultKey = vk
        cachedItems = payload.items
        isDecoyFlag = payload.decoy
        secondEnabledFlag = payload.secondEnabled
        recoverySavedFlag = payload.recoverySaved
    }

    private func persistCurrent() throws {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster,
              let wrapRecovery = currentWrapRecovery, let slotIndex = openedSlot,
              let other = otherSlotBytes, let items = cachedItems else { throw VaultError.locked }
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: items,
                                   isDecoy: isDecoyFlag ? true : nil,
                                   secondPasswordEnabled: secondEnabledFlag ? true : nil,
                                   recoveryKeySaved: recoverySavedFlag ? true : nil)
        let ct = try encryptPayload(payload, vk: vk, salt: salt)
        let slot = try VaultContainerV3.buildSlot(salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                                                  payloadCiphertext: ct, slotSize: slotSize)
        try writeContainer(current: slot, currentIndex: slotIndex, other: other)
    }

    private func writeContainer(current: Data, currentIndex: Int, other: Data) throws {
        let slot0 = currentIndex == 0 ? current : other
        let slot1 = currentIndex == 0 ? other : current
        let data = VaultContainerV3.serialize(iterations: kdfIterations, slotSize: slotSize, slot0: slot0, slot1: slot1)
        try writeAtomically(data)
    }

    private func encryptPayload(_ payload: VaultPayload, vk: SymmetricKey, salt: Data) throws -> Data {
        let json = try makeEncoder().encode(payload)
        let inner = try VaultContainerV3.makeInner(payloadJSON: json, innerSize: VaultContainerV3.innerSize(slotSize: slotSize))
        return try Crypto.encrypt(inner, using: vk, aad: aad(salt))
    }

    private func decryptPayload(ciphertext: Data, vk: SymmetricKey, salt: Data) throws -> VaultPayload {
        let inner = try Crypto.decrypt(ciphertext, using: vk, aad: aad(salt))
        guard let json = VaultContainerV3.parseInner(inner) else { throw VaultError.corrupted }
        do { return try makeDecoder().decode(VaultPayload.self, from: json) }
        catch { throw VaultError.corrupted }
    }

    private func wrap(_ vk: SymmetricKey, credential: Data, salt: Data) throws -> Data {
        let kek = try KDF.derive(password: credential, parameters: params(salt))
        return try Crypto.wrap(key: vk, with: kek)
    }

    private func params(_ salt: Data) -> KDFParameters {
        KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: kdfIterations, salt: salt)
    }

    private func aad(_ salt: Data) -> Data {
        var d = VaultContainerV3.immutableMeta(iterations: kdfIterations)
        d.append(salt)
        return d
    }

    private func randomBit() throws -> Int { Int((try Random.bytes(1))[0] & 1) }

    // MARK: - Миграции

    private func migrateV2(data: Data, password: Data) throws {
        let container = try VaultContainer.parse(data)
        let iters = container.iterations
        let metaV2 = VaultContainer.immutableMeta(iterations: iters)
        for slot in container.slots {
            let d = VaultContainer.decodeSlot(slot)
            let kek = try KDF.derive(password: password, parameters:
                KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: iters, salt: d.salt))
            guard let vk = try? Crypto.unwrap(d.wrappedVK, with: kek) else { continue }
            var aadV2 = metaV2; aadV2.append(d.salt); aadV2.append(d.wrappedVK)
            guard d.l > 0, VaultContainer.slotHeaderLen + d.l <= container.slotSize,
                  let pt = try? Crypto.decrypt(d.ciphertext, using: vk, aad: aadV2),
                  let payload = try? makeDecoder().decode(VaultPayload.self, from: pt) else { continue }
            try installMigrated(password: password, vk: vk, items: payload.items)
            return
        }
        throw VaultError.wrongPassword
    }

    private func migrateV1(data: Data, password: Data) throws {
        let file: VaultFileOnDisk
        do { file = try makeDecoder().decode(VaultFileOnDisk.self, from: data) }
        catch { throw VaultError.corrupted }
        guard file.format == VaultFormat.magic else { throw VaultError.corrupted }
        let header: VaultHeader
        do { header = try makeDecoder().decode(VaultHeader.self, from: file.header) }
        catch { throw VaultError.corrupted }
        guard header.formatVersion == 1 else { throw VaultError.unsupportedVersion(header.formatVersion) }
        let kek = try KDF.derive(password: password, parameters: header.kdf)
        let vk = try Crypto.unwrap(header.wrappedVaultKey, with: kek)
        var plaintext = try Crypto.decrypt(file.ciphertext, using: vk, aad: file.header)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let payload: VaultPayload
        do { payload = try makeDecoder().decode(VaultPayload.self, from: plaintext) }
        catch { throw VaultError.corrupted }
        try installMigrated(password: password, vk: vk, items: payload.items)
    }

    /// Пишет мигрированный сейф как v3. Ключ восстановления НЕ генерируется (его негде
    /// показать при тихой миграции) — обёртка восстановления случайная, recoverySaved=false;
    /// пользователю предложат создать ключ в Настройках.
    private func installMigrated(password: Data, vk: SymmetricKey, items: [VaultItem]) throws {
        kdfIterations = config.kdfIterations
        let salt = try Random.bytes(16)
        let wrapMaster = try wrap(vk, credential: password, salt: salt)
        let wrapRecovery = try Random.bytes(VaultContainerV3.wrapLen)
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: items,
                                   isDecoy: false, secondPasswordEnabled: false, recoveryKeySaved: false)
        try installFreshV3(vk: vk, salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery, payload: payload)
    }

    // MARK: - Ввод-вывод

    private func writeAtomically(_ data: Data) throws {
        let directory = config.fileURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw VaultError.ioError("createDirectory failed: \(error)") }
        let tmp = directory.appendingPathComponent(".vault.\(UUID().uuidString).tmp")
        do {
            do { try data.write(to: tmp, options: [.completeFileProtection]) }
            catch { try data.write(to: tmp) }
        } catch { throw VaultError.ioError("write temp failed: \(error)") }
        do {
            if FileManager.default.fileExists(atPath: config.fileURL.path) {
                _ = try FileManager.default.replaceItemAt(config.fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: config.fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw VaultError.ioError("atomic replace failed: \(error)")
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                               ofItemAtPath: config.fileURL.path)
    }

    private func readFile() throws -> Data {
        do { return try Data(contentsOf: config.fileURL) }
        catch { throw VaultError.ioError("read failed: \(error)") }
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }
    private func makeDecoder() -> JSONDecoder { JSONDecoder() }
}
