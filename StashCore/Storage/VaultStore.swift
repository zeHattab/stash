import Foundation
import CryptoKit

/// Зашифрованное хранилище. Контейнер v2 — ровно два равных слота (см. VaultContainer).
/// Мастер-пароль открывает один слот, второй пароль (если включён) — другой (ложный).
///
/// Иерархия ключей в слоте: пароль --PBKDF2--> KEK --AES-GCM--> обёрнутый VK;
/// VK --AES-GCM (AAD = неизменяемые метаданные ++ соль ++ обёрнутый VK)--> payload.
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

    // Чувствительное состояние (когда разблокировано):
    private var vaultKey: SymmetricKey?
    private var cachedItems: [VaultItem]?
    private var openedSlot: Int?
    private var currentSalt: Data?
    private var currentWrappedVK: Data?
    private var otherSlotBytes: Data?
    private var slotSize = VaultContainer.step
    private var kdfIterations: UInt32
    private var isDecoyFlag = false
    private var secondEnabledFlag = false

    public init(configuration: Configuration) {
        self.config = configuration
        self.kdfIterations = configuration.kdfIterations
    }

    // MARK: - Публичный API

    public var isUnlocked: Bool { vaultKey != nil }
    public func currentIsDecoy() -> Bool { isDecoyFlag }
    public func currentSecondPasswordEnabled() -> Bool { secondEnabledFlag }

    /// Только для тестов: индекс открытого слота (0/1).
    func openedSlotForTesting() -> Int? { openedSlot }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: config.fileURL.path)
    }

    public func create(masterPassword: String) throws {
        guard !exists() else { throw VaultError.alreadyExists }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let vk = SymmetricKey(size: .bits256)
        let salt = try Random.bytes(16)
        let kek = try KDF.derive(password: password, parameters: params(salt))
        let wrapped = try Crypto.wrap(key: vk, with: kek)
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion,
                                   items: [], isDecoy: false, secondPasswordEnabled: false)
        let ciphertext = try Crypto.encrypt(encode(payload), using: vk, aad: aad(salt: salt, wrapped: wrapped))
        let size = VaultContainer.slotSize(forCiphertextLength: ciphertext.count)
        let realSlot = try VaultContainer.encodeSlot(salt: salt, wrappedVK: wrapped, ciphertext: ciphertext, slotSize: size)
        let otherSlot = try Random.bytes(size)

        let realIndex = try randomBit()
        try writeContainer(size: size, current: realSlot, currentIndex: realIndex, other: otherSlot)

        openedSlot = realIndex
        otherSlotBytes = otherSlot
        currentSalt = salt
        currentWrappedVK = wrapped
        vaultKey = vk
        cachedItems = []
        slotSize = size
        isDecoyFlag = false
        secondEnabledFlag = false
    }

    public func unlock(masterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let data = try readFile()
        if !VaultContainer.isV2(data) {
            try migrateV1(data: data, password: password)
            return
        }
        let container = try VaultContainer.parse(data)
        kdfIterations = container.iterations
        slotSize = container.slotSize

        let d0 = VaultContainer.decodeSlot(container.slots[0])
        let d1 = VaultContainer.decodeSlot(container.slots[1])
        // KDF по ОБЕИМ солям выполняется всегда (симметрия по времени).
        let kek0 = try KDF.derive(password: password, parameters: params(d0.salt))
        let kek1 = try KDF.derive(password: password, parameters: params(d1.salt))
        let vk0 = try? Crypto.unwrap(d0.wrappedVK, with: kek0)
        let vk1 = try? Crypto.unwrap(d1.wrappedVK, with: kek1)

        var sawCorrupted = false
        for (index, slot, vk) in [(0, d0, vk0), (1, d1, vk1)] {
            guard let vk else { continue }
            guard slot.l > 0, VaultContainer.slotHeaderLen + slot.l <= slotSize,
                  let plaintext = try? Crypto.decrypt(slot.ciphertext, using: vk,
                                                      aad: aad(salt: slot.salt, wrapped: slot.wrappedVK)),
                  let payload = try? makeDecoder().decode(VaultPayload.self, from: plaintext)
            else { sawCorrupted = true; continue }

            openedSlot = index
            currentSalt = slot.salt
            currentWrappedVK = slot.wrappedVK
            otherSlotBytes = container.slots[1 - index]
            vaultKey = vk
            cachedItems = payload.items
            isDecoyFlag = payload.decoy
            secondEnabledFlag = payload.secondEnabled
            return
        }
        throw sawCorrupted ? VaultError.corrupted : VaultError.wrongPassword
    }

    /// Разблокировка готовым Vault Key (Face ID, только когда второй пароль выключен).
    public func unlock(vaultKey vk: SymmetricKey) throws {
        guard exists() else { throw VaultError.notFound }
        let data = try readFile()
        guard VaultContainer.isV2(data) else { throw VaultError.corrupted }
        let container = try VaultContainer.parse(data)
        kdfIterations = container.iterations
        slotSize = container.slotSize
        for index in 0..<2 {
            let slot = VaultContainer.decodeSlot(container.slots[index])
            guard slot.l > 0, VaultContainer.slotHeaderLen + slot.l <= slotSize,
                  let plaintext = try? Crypto.decrypt(slot.ciphertext, using: vk,
                                                      aad: aad(salt: slot.salt, wrapped: slot.wrappedVK)),
                  let payload = try? makeDecoder().decode(VaultPayload.self, from: plaintext)
            else { continue }
            openedSlot = index
            currentSalt = slot.salt
            currentWrappedVK = slot.wrappedVK
            otherSlotBytes = container.slots[1 - index]
            vaultKey = vk
            cachedItems = payload.items
            isDecoyFlag = payload.decoy
            secondEnabledFlag = payload.secondEnabled
            return
        }
        throw VaultError.corrupted
    }

    public func exportVaultKey() throws -> SymmetricKey {
        guard let vk = vaultKey, isUnlocked else { throw VaultError.locked }
        return vk
    }

    public func lock() {
        vaultKey = nil
        cachedItems = nil
        openedSlot = nil
        currentSalt = nil
        currentWrappedVK = nil
        otherSlotBytes = nil
        isDecoyFlag = false
        secondEnabledFlag = false
    }

    public func items() throws -> [VaultItem] {
        guard let items = cachedItems, isUnlocked else { throw VaultError.locked }
        return items
    }

    public func upsert(_ item: VaultItem) throws {
        guard var items = cachedItems, isUnlocked else { throw VaultError.locked }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
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
        guard let vk = vaultKey, let salt = currentSalt, let wrapped = currentWrappedVK, isUnlocked else {
            throw VaultError.locked
        }
        var oldPw = Data(old.utf8); var newPw = Data(new.utf8)
        defer { oldPw.resetBytes(in: 0..<oldPw.count); newPw.resetBytes(in: 0..<newPw.count) }
        let oldKek = try KDF.derive(password: oldPw, parameters: params(salt))
        guard (try? Crypto.unwrap(wrapped, with: oldKek)) != nil else { throw VaultError.wrongPassword }

        let newSalt = try Random.bytes(16)
        let newKek = try KDF.derive(password: newPw, parameters: params(newSalt))
        let newWrapped = try Crypto.wrap(key: vk, with: newKek)
        currentSalt = newSalt
        currentWrappedVK = newWrapped
        try persistCurrent()
    }

    // MARK: - Второй пароль

    public func enableSecondVault(secondPassword: String, sampleItems: [VaultItem]) throws {
        guard let vk = vaultKey, let salt = currentSalt, let wrapped = currentWrappedVK,
              let other = otherSlotBytes, let slotIndex = openedSlot, isUnlocked else {
            throw VaultError.locked
        }
        guard !isDecoyFlag else { return } // из ложного сейфа сюда не ходим
        var second = Data(secondPassword.utf8)
        defer { second.resetBytes(in: 0..<second.count) }
        // Второй пароль обязан отличаться от мастера: если он открывает текущий слот — отказ.
        let probeKek = try KDF.derive(password: second, parameters: params(salt))
        if (try? Crypto.unwrap(wrapped, with: probeKek)) != nil {
            throw VaultError.secondPasswordMustDiffer
        }

        // Ложный сейф в другой слот.
        let vk2 = SymmetricKey(size: .bits256)
        let salt2 = try Random.bytes(16)
        let kek2 = try KDF.derive(password: second, parameters: params(salt2))
        let wrapped2 = try Crypto.wrap(key: vk2, with: kek2)
        let decoyPayload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion,
                                        items: sampleItems, isDecoy: true, secondPasswordEnabled: false)
        let decoyCT = try Crypto.encrypt(encode(decoyPayload), using: vk2, aad: aad(salt: salt2, wrapped: wrapped2))

        // Текущий слот — перезаписываем с флагом secondPasswordEnabled = true.
        secondEnabledFlag = true
        let currentPayload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion,
                                          items: cachedItems ?? [], isDecoy: false, secondPasswordEnabled: true)
        let currentCT = try Crypto.encrypt(encode(currentPayload), using: vk, aad: aad(salt: salt, wrapped: wrapped))

        // Оба слота одной ступени.
        let need = max(VaultContainer.slotHeaderLen + decoyCT.count, VaultContainer.slotHeaderLen + currentCT.count)
        let size = need > slotSize ? VaultContainer.slotSize(forCiphertextLength: need - VaultContainer.slotHeaderLen) : slotSize
        slotSize = size
        _ = other // старый случайный слот больше не нужен — его место занимает ложный
        let currentSlot = try VaultContainer.encodeSlot(salt: salt, wrappedVK: wrapped, ciphertext: currentCT, slotSize: size)
        let decoySlot = try VaultContainer.encodeSlot(salt: salt2, wrappedVK: wrapped2, ciphertext: decoyCT, slotSize: size)
        otherSlotBytes = decoySlot
        try writeContainer(size: size, current: currentSlot, currentIndex: slotIndex, other: decoySlot)
    }

    public func disableSecondVault(masterPassword: String) throws {
        guard let salt = currentSalt, let wrapped = currentWrappedVK, isUnlocked else { throw VaultError.locked }
        guard !isDecoyFlag else { return }
        var pw = Data(masterPassword.utf8); defer { pw.resetBytes(in: 0..<pw.count) }
        let kek = try KDF.derive(password: pw, parameters: params(salt))
        guard (try? Crypto.unwrap(wrapped, with: kek)) != nil else { throw VaultError.wrongPassword }
        // Затираем другой слот случайными байтами.
        otherSlotBytes = try Random.bytes(slotSize)
        secondEnabledFlag = false
        try persistCurrent()
    }

    /// Меняет только флаг secondPasswordEnabled в ТЕКУЩЕМ слоте (используется в ложном
    /// сейфе: сценарий проходит до конца, но чужой слот не трогается).
    public func setSecondPasswordFlag(_ enabled: Bool) throws {
        guard isUnlocked else { throw VaultError.locked }
        secondEnabledFlag = enabled
        try persistCurrent()
    }

    // MARK: - Внутреннее

    private func persistCurrent() throws {
        guard let vk = vaultKey, let salt = currentSalt, let wrapped = currentWrappedVK,
              let slotIndex = openedSlot, var other = otherSlotBytes, let items = cachedItems else {
            throw VaultError.locked
        }
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion,
                                   items: items,
                                   isDecoy: isDecoyFlag ? true : nil,
                                   secondPasswordEnabled: secondEnabledFlag ? true : nil)
        let ciphertext = try Crypto.encrypt(encode(payload), using: vk, aad: aad(salt: salt, wrapped: wrapped))
        var size = slotSize
        if VaultContainer.slotHeaderLen + ciphertext.count > size {
            let newSize = VaultContainer.slotSize(forCiphertextLength: ciphertext.count)
            other.append(try Random.bytes(newSize - size)) // растут оба слота
            size = newSize
            slotSize = newSize
            otherSlotBytes = other
        }
        let currentSlot = try VaultContainer.encodeSlot(salt: salt, wrappedVK: wrapped, ciphertext: ciphertext, slotSize: size)
        try writeContainer(size: size, current: currentSlot, currentIndex: slotIndex, other: other)
    }

    private func writeContainer(size: Int, current: Data, currentIndex: Int, other: Data) throws {
        let slot0 = currentIndex == 0 ? current : other
        let slot1 = currentIndex == 0 ? other : current
        let data = VaultContainer.serialize(iterations: kdfIterations, slotSize: size, slot0: slot0, slot1: slot1)
        try writeAtomically(data)
    }

    private func migrateV1(data: Data, password: Data) throws {
        // Читаем старый формат v1 (JSON), расшифровываем, пере-записываем как v2.
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
        let oldPayload: VaultPayload
        do { oldPayload = try makeDecoder().decode(VaultPayload.self, from: plaintext) }
        catch { throw VaultError.corrupted }

        // Строим v2 с тем же VK (пароль тот же). Настоящий сейф — в случайный слот.
        kdfIterations = config.kdfIterations
        let salt = try Random.bytes(16)
        let newKek = try KDF.derive(password: password, parameters: params(salt))
        let wrapped = try Crypto.wrap(key: vk, with: newKek)
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion,
                                   items: oldPayload.items, isDecoy: false, secondPasswordEnabled: false)
        let ciphertext = try Crypto.encrypt(encode(payload), using: vk, aad: aad(salt: salt, wrapped: wrapped))
        let size = VaultContainer.slotSize(forCiphertextLength: ciphertext.count)
        let realSlot = try VaultContainer.encodeSlot(salt: salt, wrappedVK: wrapped, ciphertext: ciphertext, slotSize: size)
        let otherSlot = try Random.bytes(size)
        let realIndex = try randomBit()
        try writeContainer(size: size, current: realSlot, currentIndex: realIndex, other: otherSlot)

        openedSlot = realIndex
        otherSlotBytes = otherSlot
        currentSalt = salt
        currentWrappedVK = wrapped
        vaultKey = vk
        cachedItems = payload.items
        slotSize = size
        isDecoyFlag = false
        secondEnabledFlag = false
    }

    private func params(_ salt: Data) -> KDFParameters {
        KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: kdfIterations, salt: salt)
    }

    private func aad(salt: Data, wrapped: Data) -> Data {
        var data = VaultContainer.immutableMeta(iterations: kdfIterations)
        data.append(salt)
        data.append(wrapped)
        return data
    }

    private func randomBit() throws -> Int {
        let b = try Random.bytes(1)
        return Int(b[0] & 1)
    }

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

    private func encode(_ payload: VaultPayload) throws -> Data {
        try makeEncoder().encode(payload)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder { JSONDecoder() }
}
