import Foundation
import CryptoKit

/// Зашифрованное хранилище сейфа. Actor — все обращения сериализуются.
///
/// Иерархия ключей:
/// мастер-пароль --PBKDF2--> KEK --AES-GCM--> оборачивает случайный Vault Key (VK);
/// VK --AES-GCM (AAD = заголовок)--> шифрует полезную нагрузку.
/// Смена пароля меняет только обёртку VK (сам VK и ключ данных не меняются),
/// но полезная нагрузка пере-запечатывается, т.к. заголовок является AAD.
public actor VaultStore {

    public struct Configuration: Sendable {
        /// Путь к файлу vault.stash. Инжектится, чтобы тесты писали во временную папку.
        public var fileURL: URL
        /// Число итераций KDF (1 000 в тестах, 600 000 в бою).
        public var kdfIterations: UInt32

        public init(fileURL: URL, kdfIterations: UInt32 = 600_000) {
            self.fileURL = fileURL
            self.kdfIterations = kdfIterations
        }
    }

    private let config: Configuration

    // Чувствительное состояние (только когда разблокировано):
    private var vaultKey: SymmetricKey?
    private var cachedItems: [VaultItem]?
    private var header: VaultHeader?

    public init(configuration: Configuration) {
        self.config = configuration
    }

    // MARK: - Публичный API

    public var isUnlocked: Bool { vaultKey != nil }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: config.fileURL.path)
    }

    public func create(masterPassword: String) throws {
        guard !exists() else { throw VaultError.alreadyExists }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let kdf = try KDFParameters.makeDefault(iterations: config.kdfIterations)
        let kek = try KDF.derive(password: password, parameters: kdf)
        let vk = SymmetricKey(size: .bits256)
        let wrapped = try Crypto.wrap(key: vk, with: kek)

        let header = VaultHeader(
            formatVersion: VaultFormat.currentVersion,
            kdf: kdf,
            wrappedVaultKey: wrapped,
            wrappedVaultKeyBiometric: nil
        )
        self.header = header
        self.vaultKey = vk
        self.cachedItems = []
        try persist()
    }

    public func unlock(masterPassword: String) throws {
        guard exists() else { throw VaultError.notFound }
        var password = Data(masterPassword.utf8)
        defer { password.resetBytes(in: 0..<password.count) }

        let file = try readAndDecodeFile()
        let header = try decodeHeader(file.header)
        guard header.formatVersion == VaultFormat.currentVersion else {
            throw VaultError.unsupportedVersion(header.formatVersion)
        }
        let kek = try KDF.derive(password: password, parameters: header.kdf)
        let vk = try Crypto.unwrap(header.wrappedVaultKey, with: kek)      // wrongPassword
        var plaintext = try Crypto.decrypt(file.ciphertext, using: vk, aad: file.header) // corrupted
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }

        let payload: VaultPayload
        do { payload = try makeDecoder().decode(VaultPayload.self, from: plaintext) }
        catch { throw VaultError.corrupted }

        self.header = header
        self.vaultKey = vk
        self.cachedItems = payload.items
    }

    /// Стирает ключ и расшифрованные данные из памяти.
    ///
    /// Ограничение: надёжно обнулить можно `Data`/байтовые буферы; `SymmetricKey`
    /// хранится CryptoKit в защищённой памяти и обнуляется при освобождении ссылки.
    /// Содержимое `String` внутри моделей зафиксировать и обнулить в Swift нельзя —
    /// оно освобождается сборщиком и остаётся в памяти до переиспользования.
    public func lock() {
        vaultKey = nil
        cachedItems = nil
        header = nil
    }

    public func items() throws -> [VaultItem] {
        guard let items = cachedItems, isUnlocked else { throw VaultError.locked }
        return items
    }

    public func upsert(_ item: VaultItem) throws {
        guard var items = cachedItems, isUnlocked else { throw VaultError.locked }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        cachedItems = items
        try persist()
    }

    public func delete(id: UUID) throws {
        guard var items = cachedItems, isUnlocked else { throw VaultError.locked }
        items.removeAll { $0.id == id }
        cachedItems = items
        try persist()
    }

    public func changeMasterPassword(old: String, new: String) throws {
        guard exists() else { throw VaultError.notFound }
        var oldPassword = Data(old.utf8)
        var newPassword = Data(new.utf8)
        defer {
            oldPassword.resetBytes(in: 0..<oldPassword.count)
            newPassword.resetBytes(in: 0..<newPassword.count)
        }

        // Читаем с диска (источник истины; upsert/delete сохраняются сразу).
        let file = try readAndDecodeFile()
        let oldHeader = try decodeHeader(file.header)
        guard oldHeader.formatVersion == VaultFormat.currentVersion else {
            throw VaultError.unsupportedVersion(oldHeader.formatVersion)
        }
        let oldKek = try KDF.derive(password: oldPassword, parameters: oldHeader.kdf)
        let vk = try Crypto.unwrap(oldHeader.wrappedVaultKey, with: oldKek)      // wrongPassword
        var plaintext = try Crypto.decrypt(file.ciphertext, using: vk, aad: file.header) // corrupted
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let payload: VaultPayload
        do { payload = try makeDecoder().decode(VaultPayload.self, from: plaintext) }
        catch { throw VaultError.corrupted }

        // Новая обёртка VK под новый пароль; VK прежний.
        let newKdf = try KDFParameters.makeDefault(iterations: config.kdfIterations)
        let newKek = try KDF.derive(password: newPassword, parameters: newKdf)
        let newWrapped = try Crypto.wrap(key: vk, with: newKek)
        var newHeader = oldHeader
        newHeader.kdf = newKdf
        newHeader.wrappedVaultKey = newWrapped

        try write(header: newHeader, vaultKey: vk, items: payload.items)

        self.header = newHeader
        self.vaultKey = vk
        self.cachedItems = payload.items
    }

    // MARK: - Внутреннее

    private func persist() throws {
        guard let vk = vaultKey, let header = header, let items = cachedItems else {
            throw VaultError.locked
        }
        try write(header: header, vaultKey: vk, items: items)
    }

    private func write(header: VaultHeader, vaultKey: SymmetricKey, items: [VaultItem]) throws {
        let encoder = makeEncoder()
        let headerData = try encoder.encode(header)
        let payload = VaultPayload(schemaVersion: VaultFormat.currentSchemaVersion, items: items)
        var plaintext = try encoder.encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }

        let ciphertext = try Crypto.encrypt(plaintext, using: vaultKey, aad: headerData)
        let file = VaultFileOnDisk(format: VaultFormat.magic, header: headerData, ciphertext: ciphertext)
        let data = try encoder.encode(file)
        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = config.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw VaultError.ioError("createDirectory failed: \(error)")
        }
        let tmp = directory.appendingPathComponent(".vault.\(UUID().uuidString).tmp")
        do {
            // На устройстве пишем сразу с полной защитой; на симуляторе опция
            // может быть не поддержана — тогда пишем обычным способом.
            do {
                try data.write(to: tmp, options: [.completeFileProtection])
            } catch {
                try data.write(to: tmp)
            }
        } catch {
            throw VaultError.ioError("write temp failed: \(error)")
        }
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
        // Гарантируем защиту итогового файла (best-effort: на симуляторе игнорируется).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: config.fileURL.path
        )
    }

    private func readAndDecodeFile() throws -> VaultFileOnDisk {
        let data: Data
        do { data = try Data(contentsOf: config.fileURL) }
        catch { throw VaultError.ioError("read failed: \(error)") }
        let file: VaultFileOnDisk
        do { file = try makeDecoder().decode(VaultFileOnDisk.self, from: data) }
        catch { throw VaultError.corrupted }
        guard file.format == VaultFormat.magic else { throw VaultError.corrupted }
        return file
    }

    private func decodeHeader(_ headerData: Data) throws -> VaultHeader {
        do { return try makeDecoder().decode(VaultHeader.self, from: headerData) }
        catch { throw VaultError.corrupted }
    }

    // JSONEncoder/Decoder не Sendable — создаём локально, не держим как общее состояние.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
