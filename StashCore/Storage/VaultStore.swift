import Foundation
import CryptoKit

/// Хранилище. Контейнер v4 (см. VaultContainerV4): два равных слота без открытых полей,
/// рост дописыванием случайных байтов. VK в слоте обёрнут дважды (мастер + ключ
/// восстановления). VK и соль ЛОЖНОГО сейфа дополнительно лежат в зашифрованном payload
/// НАСТОЯЩЕГО сейфа — чтобы настоящий сейф мог управлять ложным (сменить второй пароль).
public actor VaultStore {

    public struct Configuration: Sendable {
        public var fileURL: URL
        public var kdfIterations: UInt32
        /// Только для тестов: сымитировать сбой записи (старый файл должен остаться цел).
        public var simulateWriteFailure: Bool
        public init(fileURL: URL, kdfIterations: UInt32 = 600_000, simulateWriteFailure: Bool = false) {
            self.fileURL = fileURL
            self.kdfIterations = kdfIterations
            self.simulateWriteFailure = simulateWriteFailure
        }
    }

    private var config: Configuration

    private var vaultKey: SymmetricKey?
    private var cachedItems: [VaultItem]?
    private var openedSlot: Int?
    private var currentSalt: Data?
    private var currentWrapMaster: Data?
    private var currentWrapRecovery: Data?
    private var otherSlotBytes: Data?
    private var slotSize = VaultContainerV4.steps[0]
    private var kdfIterations: UInt32
    private var isDecoyFlag = false
    private var secondEnabledFlag = false
    private var recoverySavedFlag = false
    private var decoyNeedsFillingFlag = false
    private var currentDecoyVKData: Data?
    private var currentDecoySalt: Data?

    public init(configuration: Configuration) {
        self.config = configuration
        self.kdfIterations = configuration.kdfIterations
    }

    // MARK: - Состояние

    public var isUnlocked: Bool { vaultKey != nil }
    public func currentIsDecoy() -> Bool { isDecoyFlag }
    public func currentSecondPasswordEnabled() -> Bool { secondEnabledFlag }
    public func currentRecoveryKeySaved() -> Bool { recoverySavedFlag }
    public func currentDecoyNeedsFilling() -> Bool { decoyNeedsFillingFlag }

    /// Непрозрачный тег открытого сейфа для привязки локальных уведомлений.
    /// Хэш соли слота (соль неизменна за жизнь слота в v4) с доменным разделителем —
    /// у настоящего и ложного сейфов он разный, саму соль не раскрывает.
    public func currentVaultTag() -> String? {
        guard let salt = currentSalt else { return nil }
        let digest = SHA256.hash(data: Data("stash-notif-tag".utf8) + salt)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func openedSlotForTesting() -> Int? { openedSlot }
    func slotSizeForTesting() -> Int { slotSize }
    func setSimulateWriteFailureForTesting(_ value: Bool) { config.simulateWriteFailure = value }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: config.fileURL.path) }

    // MARK: - Создание

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
        try installFresh(vk: vk, salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery, payload: payload)
        return recoveryKey
    }

    // MARK: - Разблокировка

    public func unlock(masterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }
        let data = try readFile()
        if VaultContainerV4.isV4(data) {
            try openV4(data: data, credential: password)
        } else if VaultContainerV3.isV3(data) {
            try migrateFromV3(data: data, password: password)
        } else if VaultContainer.isV2(data) {
            try migrateFromV2(data: data, password: password)
        } else {
            try migrateFromV1(data: data, password: password)
        }
    }

    public func unlock(vaultKey vk: SymmetricKey) throws {
        guard exists() else { throw VaultError.notFound }
        let data = try readFile()
        guard VaultContainerV4.isV4(data) else { throw VaultError.corrupted }
        let container = try VaultContainerV4.parse(data)
        kdfIterations = container.iterations; slotSize = container.slotSize
        for index in 0..<2 {
            let s = VaultContainerV4.parseSlot(container.slots[index])
            guard let payload = try? decryptPayload(lenBlock: s.lenBlock, body: s.body, vk: vk, salt: s.salt) else { continue }
            setOpened(index: index, salt: s.salt, wrapMaster: s.wrapMaster, wrapRecovery: s.wrapRecovery,
                      vk: vk, payload: payload, container: container)
            return
        }
        throw VaultError.corrupted
    }

    public func recoverWithKey(_ recoveryKey: String, newMasterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        let data = try readFile()
        guard VaultContainerV4.isV4(data) else { throw VaultError.corrupted }
        let container = try VaultContainerV4.parse(data)
        kdfIterations = container.iterations; slotSize = container.slotSize
        var keyData = RecoveryKey.keyData(recoveryKey)
        var newPw = Data(newMasterPassword.utf8)
        defer { keyData.resetBytes(in: 0..<keyData.count); newPw.resetBytes(in: 0..<newPw.count) }
        let s0 = VaultContainerV4.parseSlot(container.slots[0])
        let s1 = VaultContainerV4.parseSlot(container.slots[1])
        let kek0 = try KDF.derive(password: keyData, parameters: params(s0.salt))
        let kek1 = try KDF.derive(password: keyData, parameters: params(s1.salt))
        for (index, s, kek) in [(0, s0, kek0), (1, s1, kek1)] {
            guard let vk = try? Crypto.unwrap(s.wrapRecovery, with: kek),
                  let payload = try? decryptPayload(lenBlock: s.lenBlock, body: s.body, vk: vk, salt: s.salt) else { continue }
            let newWrapMaster = try wrap(vk, credential: newPw, salt: s.salt)
            setOpened(index: index, salt: s.salt, wrapMaster: s.wrapMaster, wrapRecovery: s.wrapRecovery,
                      vk: vk, payload: payload, container: container)
            currentWrapMaster = newWrapMaster
            try persistCurrent()
            return
        }
        throw VaultError.wrongPassword
    }

    // MARK: - Ключ восстановления

    @discardableResult
    public func regenerateRecoveryKey(masterPassword: String) throws -> String {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster, isUnlocked else {
            throw VaultError.locked
        }
        var pw = Data(masterPassword.utf8); defer { pw.resetBytes(in: 0..<pw.count) }
        guard (try? Crypto.unwrap(wrapMaster, with: KDF.derive(password: pw, parameters: params(salt)))) != nil else {
            throw VaultError.wrongPassword
        }
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
        currentSalt = nil; currentWrapMaster = nil; currentWrapRecovery = nil; otherSlotBytes = nil
        isDecoyFlag = false; secondEnabledFlag = false; recoverySavedFlag = false; decoyNeedsFillingFlag = false
        currentDecoyVKData = nil; currentDecoySalt = nil
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
        guard (try? Crypto.unwrap(wrapMaster, with: KDF.derive(password: oldPw, parameters: params(salt)))) != nil else {
            throw VaultError.wrongPassword
        }
        currentWrapMaster = try wrap(vk, credential: newPw, salt: salt)
        try persistCurrent()
    }

    // MARK: - Второй пароль

    public func probeSecondPasswordCollides(_ second: String) -> Bool {
        guard let salt = currentSalt, let wm = currentWrapMaster, let wr = currentWrapRecovery, isUnlocked,
              let kek = try? KDF.derive(password: Data(second.utf8), parameters: params(salt)) else { return false }
        return (try? Crypto.unwrap(wm, with: kek)) != nil || (try? Crypto.unwrap(wr, with: kek)) != nil
    }

    @discardableResult
    public func enableSecondVault(secondPassword: String, sampleItems: [VaultItem]) throws -> String {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster,
              let wrapRecovery = currentWrapRecovery, let slotIndex = openedSlot, isUnlocked else {
            throw VaultError.locked
        }
        guard !isDecoyFlag else { return "" }
        var second = Data(secondPassword.utf8); defer { second.resetBytes(in: 0..<second.count) }
        let probe = try KDF.derive(password: second, parameters: params(salt))
        if (try? Crypto.unwrap(wrapMaster, with: probe)) != nil || (try? Crypto.unwrap(wrapRecovery, with: probe)) != nil {
            throw VaultError.secondPasswordMustDiffer
        }

        let vk2 = SymmetricKey(size: .bits256)
        let salt2 = try Random.bytes(16)
        let decoyRecovery = try RecoveryKey.generate()
        let wrapM2 = try wrap(vk2, credential: second, salt: salt2)
        let wrapR2 = try wrap(vk2, credential: RecoveryKey.keyData(decoyRecovery), salt: salt2)
        let decoyPayload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: sampleItems,
                                        isDecoy: true, secondPasswordEnabled: false, recoveryKeySaved: false)
        let (lb2, ct2) = try encryptPayload(decoyPayload, vk: vk2, salt: salt2)

        secondEnabledFlag = true
        decoyNeedsFillingFlag = sampleItems.count < 3
        currentDecoyVKData = vk2.withUnsafeBytes { Data($0) }
        currentDecoySalt = salt2
        let (lbCur, ctCur) = try encryptPayload(currentPayload(), vk: vk, salt: salt)

        var size = slotSize
        let needed = max(VaultContainerV4.headLen + ct2.count, VaultContainerV4.headLen + ctCur.count)
        if needed > size { size = try VaultContainerV4.slotSize(forCiphertextLength: max(ct2.count, ctCur.count)) }
        slotSize = size

        let curSlot = try VaultContainerV4.buildSlot(salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                                                     lenBlock: lbCur, ciphertext: ctCur, slotSize: size)
        let decoySlot = try VaultContainerV4.buildSlot(salt: salt2, wrapMaster: wrapM2, wrapRecovery: wrapR2,
                                                       lenBlock: lb2, ciphertext: ct2, slotSize: size)
        otherSlotBytes = decoySlot
        try writeContainer(current: curSlot, currentIndex: slotIndex, other: decoySlot)
        return decoyRecovery
    }

    /// Сменить второй пароль. Содержимое ложного сейфа сохраняется (переобёртываем только
    /// его мастер-обёртку, зная VK ложного сейфа из payload настоящего).
    public func changeSecondPassword(master: String, newSecond: String) throws {
        guard let salt = currentSalt, let wrapMaster = currentWrapMaster, let wrapRecovery = currentWrapRecovery,
              let decoyVKData = currentDecoyVKData, let slotIndex = openedSlot, isUnlocked, !isDecoyFlag else {
            throw VaultError.locked
        }
        var masterPw = Data(master.utf8); var newPw = Data(newSecond.utf8)
        defer { masterPw.resetBytes(in: 0..<masterPw.count); newPw.resetBytes(in: 0..<newPw.count) }
        guard (try? Crypto.unwrap(wrapMaster, with: KDF.derive(password: masterPw, parameters: params(salt)))) != nil else {
            throw VaultError.wrongPassword
        }
        let probe = try KDF.derive(password: newPw, parameters: params(salt))
        if (try? Crypto.unwrap(wrapMaster, with: probe)) != nil || (try? Crypto.unwrap(wrapRecovery, with: probe)) != nil {
            throw VaultError.secondPasswordMustDiffer
        }
        // Работаем с сырыми байтами: НАСТОЯЩИЙ слот остаётся байт-в-байт неизменным.
        let container = try VaultContainerV4.parse(try readFile())
        let realRaw = container.slots[slotIndex]
        let d = VaultContainerV4.parseSlot(container.slots[1 - slotIndex])
        let decoyVK = SymmetricKey(data: decoyVKData)
        guard let lenData = try? Crypto.decrypt(d.lenBlock, using: decoyVK, aad: aad(d.salt)),
              let L = VaultContainerV4.decodeLength(lenData), L >= 0, L <= d.body.count else {
            throw VaultError.corrupted
        }
        let decoyCT = Data([UInt8](d.body)[0..<L])
        let newWrapM2 = try wrap(decoyVK, credential: newPw, salt: d.salt)
        let newDecoy = try VaultContainerV4.buildSlot(salt: d.salt, wrapMaster: newWrapM2, wrapRecovery: d.wrapRecovery,
                                                      lenBlock: d.lenBlock, ciphertext: decoyCT, slotSize: container.slotSize)
        let slot0 = slotIndex == 0 ? realRaw : newDecoy
        let slot1 = slotIndex == 0 ? newDecoy : realRaw
        try writeAtomically(VaultContainerV4.serialize(iterations: kdfIterations, slotSize: container.slotSize,
                                                       slot0: slot0, slot1: slot1))
        otherSlotBytes = newDecoy
    }

    public func disableSecondVault(masterPassword: String) throws {
        guard let salt = currentSalt, let wrapMaster = currentWrapMaster, isUnlocked, !isDecoyFlag else {
            throw VaultError.locked
        }
        var pw = Data(masterPassword.utf8); defer { pw.resetBytes(in: 0..<pw.count) }
        guard (try? Crypto.unwrap(wrapMaster, with: KDF.derive(password: pw, parameters: params(salt)))) != nil else {
            throw VaultError.wrongPassword
        }
        otherSlotBytes = try Random.bytes(slotSize)
        secondEnabledFlag = false
        decoyNeedsFillingFlag = false
        currentDecoyVKData = nil
        currentDecoySalt = nil
        try persistCurrent()
    }

    public func setSecondPasswordFlag(_ enabled: Bool) throws {
        guard isUnlocked else { throw VaultError.locked }
        secondEnabledFlag = enabled
        try persistCurrent()
    }

    // MARK: - Внутреннее

    private func currentPayload() -> VaultPayload {
        VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: cachedItems ?? [],
                     isDecoy: isDecoyFlag ? true : nil,
                     secondPasswordEnabled: secondEnabledFlag ? true : nil,
                     recoveryKeySaved: recoverySavedFlag ? true : nil,
                     decoyNeedsFilling: decoyNeedsFillingFlag ? true : nil,
                     decoyVaultKey: currentDecoyVKData,
                     decoySalt: currentDecoySalt)
    }

    private func openV4(data: Data, credential: Data) throws {
        let container = try VaultContainerV4.parse(data)
        kdfIterations = container.iterations; slotSize = container.slotSize
        let s0 = VaultContainerV4.parseSlot(container.slots[0])
        let s1 = VaultContainerV4.parseSlot(container.slots[1])
        let kek0 = try KDF.derive(password: credential, parameters: params(s0.salt))
        let kek1 = try KDF.derive(password: credential, parameters: params(s1.salt))
        var sawCorrupted = false
        for (index, s, kek) in [(0, s0, kek0), (1, s1, kek1)] {
            let vk = (try? Crypto.unwrap(s.wrapMaster, with: kek)) ?? (try? Crypto.unwrap(s.wrapRecovery, with: kek))
            guard let vk else { continue }
            guard let payload = try? decryptPayload(lenBlock: s.lenBlock, body: s.body, vk: vk, salt: s.salt) else {
                sawCorrupted = true; continue
            }
            setOpened(index: index, salt: s.salt, wrapMaster: s.wrapMaster, wrapRecovery: s.wrapRecovery,
                      vk: vk, payload: payload, container: container)
            return
        }
        throw sawCorrupted ? VaultError.corrupted : VaultError.wrongPassword
    }

    private func setOpened(index: Int, salt: Data, wrapMaster: Data, wrapRecovery: Data,
                           vk: SymmetricKey, payload: VaultPayload, container: VaultContainerV4.Container) {
        openedSlot = index
        currentSalt = salt
        currentWrapMaster = wrapMaster
        currentWrapRecovery = wrapRecovery
        otherSlotBytes = container.slots[1 - index]
        vaultKey = vk
        cachedItems = payload.items
        isDecoyFlag = payload.decoy
        secondEnabledFlag = payload.secondEnabled
        recoverySavedFlag = payload.recoverySaved
        decoyNeedsFillingFlag = payload.decoySparse
        currentDecoyVKData = payload.decoyVaultKey
        currentDecoySalt = payload.decoySalt
    }

    private func installFresh(vk: SymmetricKey, salt: Data, wrapMaster: Data, wrapRecovery: Data, payload: VaultPayload) throws {
        let (lenBlock, ct) = try encryptPayloadRaw(payload, vk: vk, salt: salt)
        slotSize = try VaultContainerV4.slotSize(forCiphertextLength: ct.count)
        let realSlot = try VaultContainerV4.buildSlot(salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                                                      lenBlock: lenBlock, ciphertext: ct, slotSize: slotSize)
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
        decoyNeedsFillingFlag = payload.decoySparse
        currentDecoyVKData = payload.decoyVaultKey
        currentDecoySalt = payload.decoySalt
    }

    private func persistCurrent() throws {
        guard let vk = vaultKey, let salt = currentSalt, let wrapMaster = currentWrapMaster,
              let wrapRecovery = currentWrapRecovery, let slotIndex = openedSlot, var other = otherSlotBytes,
              cachedItems != nil else { throw VaultError.locked }
        let (lenBlock, ct) = try encryptPayload(currentPayload(), vk: vk, salt: salt)
        var size = slotSize
        if VaultContainerV4.headLen + ct.count > size {
            let newSize = try VaultContainerV4.slotSize(forCiphertextLength: ct.count)
            other.append(try Random.bytes(newSize - size)) // растут ОБА слота (дописывание)
            size = newSize
            slotSize = newSize
            otherSlotBytes = other
        }
        let slot = try VaultContainerV4.buildSlot(salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                                                  lenBlock: lenBlock, ciphertext: ct, slotSize: size)
        try writeContainer(current: slot, currentIndex: slotIndex, other: other)
    }

    private func writeContainer(current: Data, currentIndex: Int, other: Data) throws {
        let slot0 = currentIndex == 0 ? current : other
        let slot1 = currentIndex == 0 ? other : current
        try writeAtomically(VaultContainerV4.serialize(iterations: kdfIterations, slotSize: slotSize, slot0: slot0, slot1: slot1))
    }

    private func encryptPayload(_ payload: VaultPayload, vk: SymmetricKey, salt: Data) throws -> (lenBlock: Data, ciphertext: Data) {
        try encryptPayloadRaw(payload, vk: vk, salt: salt)
    }

    private func encryptPayloadRaw(_ payload: VaultPayload, vk: SymmetricKey, salt: Data) throws -> (lenBlock: Data, ciphertext: Data) {
        let json = try makeEncoder().encode(payload)
        let ct = try Crypto.encrypt(json, using: vk, aad: aad(salt))
        let lenBlock = try Crypto.encrypt(VaultContainerV4.encodeLength(ct.count), using: vk, aad: aad(salt))
        return (lenBlock, ct)
    }

    private func decryptPayload(lenBlock: Data, body: Data, vk: SymmetricKey, salt: Data) throws -> VaultPayload {
        let lenData = try Crypto.decrypt(lenBlock, using: vk, aad: aad(salt))
        guard let L = VaultContainerV4.decodeLength(lenData), L >= 0, L <= body.count else { throw VaultError.corrupted }
        let ct = Data([UInt8](body)[0..<L])
        let json = try Crypto.decrypt(ct, using: vk, aad: aad(salt))
        do { return try makeDecoder().decode(VaultPayload.self, from: json) }
        catch { throw VaultError.corrupted }
    }

    private func wrap(_ vk: SymmetricKey, credential: Data, salt: Data) throws -> Data {
        try Crypto.wrap(key: vk, with: KDF.derive(password: credential, parameters: params(salt)))
    }
    private func params(_ salt: Data) -> KDFParameters {
        KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: kdfIterations, salt: salt)
    }
    private func aad(_ salt: Data) -> Data {
        var d = VaultContainerV4.immutableMeta(iterations: kdfIterations); d.append(salt); return d
    }
    private func randomBit() throws -> Int { Int((try Random.bytes(1))[0] & 1) }

    // MARK: - Миграции

    private func migrateFromV3(data: Data, password: Data) throws {
        let container = try VaultContainerV3.parse(data)
        for slot in container.slots {
            let s = VaultContainerV3.parseSlot(slot)
            let kek = try KDF.derive(password: password, parameters:
                KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: container.iterations, salt: s.salt))
            let vk = (try? Crypto.unwrap(s.wrapMaster, with: kek)) ?? (try? Crypto.unwrap(s.wrapRecovery, with: kek))
            guard let vk,
                  let inner = try? Crypto.decrypt(s.ciphertext, using: vk, aad: aadV3(iters: container.iterations, salt: s.salt)),
                  let json = VaultContainerV3.parseInner(inner),
                  let payload = try? makeDecoder().decode(VaultPayload.self, from: json) else { continue }
            // Переносим открытый слот, сохраняя его соль и обе обёртки (ключ восстановления жив).
            kdfIterations = config.kdfIterations
            try installFresh(vk: vk, salt: s.salt, wrapMaster: s.wrapMaster, wrapRecovery: s.wrapRecovery,
                             payload: freshRealPayload(items: payload.items, recoverySaved: payload.recoverySaved))
            return
        }
        throw VaultError.wrongPassword
    }

    private func migrateFromV2(data: Data, password: Data) throws {
        let container = try VaultContainer.parse(data)
        let meta = VaultContainer.immutableMeta(iterations: container.iterations)
        for slot in container.slots {
            let d = VaultContainer.decodeSlot(slot)
            let kek = try KDF.derive(password: password, parameters:
                KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: container.iterations, salt: d.salt))
            guard let vk = try? Crypto.unwrap(d.wrappedVK, with: kek) else { continue }
            var aad2 = meta; aad2.append(d.salt); aad2.append(d.wrappedVK)
            guard d.l > 0, VaultContainer.slotHeaderLen + d.l <= container.slotSize,
                  let pt = try? Crypto.decrypt(d.ciphertext, using: vk, aad: aad2),
                  let payload = try? makeDecoder().decode(VaultPayload.self, from: pt) else { continue }
            try installMigratedFresh(password: password, vk: vk, items: payload.items)
            return
        }
        throw VaultError.wrongPassword
    }

    private func migrateFromV1(data: Data, password: Data) throws {
        let file: VaultFileOnDisk
        do { file = try makeDecoder().decode(VaultFileOnDisk.self, from: data) } catch { throw VaultError.corrupted }
        guard file.format == VaultFormat.magic else { throw VaultError.corrupted }
        let header: VaultHeader
        do { header = try makeDecoder().decode(VaultHeader.self, from: file.header) } catch { throw VaultError.corrupted }
        guard header.formatVersion == 1 else { throw VaultError.unsupportedVersion(header.formatVersion) }
        let vk = try Crypto.unwrap(header.wrappedVaultKey, with: KDF.derive(password: password, parameters: header.kdf))
        var plaintext = try Crypto.decrypt(file.ciphertext, using: vk, aad: file.header)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let payload: VaultPayload
        do { payload = try makeDecoder().decode(VaultPayload.self, from: plaintext) } catch { throw VaultError.corrupted }
        try installMigratedFresh(password: password, vk: vk, items: payload.items)
    }

    /// Миграция из v1/v2 (ключа восстановления не было): новая соль, обёртка восстановления —
    /// случайные байты (ключ восстановления создаётся позже в Настройках).
    private func installMigratedFresh(password: Data, vk: SymmetricKey, items: [VaultItem]) throws {
        kdfIterations = config.kdfIterations
        let salt = try Random.bytes(16)
        let wrapMaster = try wrap(vk, credential: password, salt: salt)
        let wrapRecovery = try Random.bytes(VaultContainerV4.wrapLen)
        try installFresh(vk: vk, salt: salt, wrapMaster: wrapMaster, wrapRecovery: wrapRecovery,
                         payload: freshRealPayload(items: items, recoverySaved: false))
    }

    private func freshRealPayload(items: [VaultItem], recoverySaved: Bool) -> VaultPayload {
        VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: items,
                     isDecoy: false, secondPasswordEnabled: false, recoveryKeySaved: recoverySaved)
    }

    private func aadV3(iters: UInt32, salt: Data) -> Data {
        var d = VaultContainerV3.immutableMeta(iterations: iters); d.append(salt); return d
    }

    // MARK: - Ввод-вывод

    private func writeAtomically(_ data: Data) throws {
        if config.simulateWriteFailure { throw VaultError.ioError("simulated write failure") }
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
        do { return try Data(contentsOf: config.fileURL) } catch { throw VaultError.ioError("read failed: \(error)") }
    }

    private func makeEncoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
    private func makeDecoder() -> JSONDecoder { JSONDecoder() }
}
