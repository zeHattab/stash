import XCTest
import CryptoKit
@testable import StashCore

final class MigrationTests: XCTestCase {

    /// Собирает файл старого формата v1 вручную и кладёт по url.
    private func writeV1(at url: URL, password: String, items: [VaultItem]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let salt = try Random.bytes(16)
        let kdf = KDFParameters(algorithm: .pbkdf2HMACSHA256, iterations: 1_000, salt: salt)
        let pw = Data(password.utf8)
        let kek = try KDF.derive(password: pw, parameters: kdf)
        let vk = SymmetricKey(size: .bits256)
        let wrapped = try Crypto.wrap(key: vk, with: kek)
        let header = VaultHeader(formatVersion: 1, kdf: kdf, wrappedVaultKey: wrapped)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)
        let payload = VaultPayload(schemaVersion: 1, items: items)
        let ciphertext = try Crypto.encrypt(encoder.encode(payload), using: vk, aad: headerData)
        let file = VaultFileOnDisk(format: VaultFormat.magic, header: headerData, ciphertext: ciphertext)
        try encoder.encode(file).write(to: url)
    }

    func testMigrateV1ToV2PreservesData() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-mig-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = VaultItem(kind: .login(username: "alice", password: "s3cret",
                                          urls: ["https://x.com"], totpSecret: nil),
                             title: "Bank", createdAt: date, updatedAt: date)
        try writeV1(at: url, password: "pw", items: [item])

        // Файл изначально НЕ v2.
        XCTAssertFalse(VaultContainer.isV2(try Data(contentsOf: url)))

        let store = VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000))
        try await store.unlock(masterPassword: "pw")   // миграция на лету
        var got = try await store.items()
        XCTAssertEqual(got, [item])

        // Теперь файл — контейнер v2 с двумя слотами.
        let data = try Data(contentsOf: url)
        XCTAssertTrue(VaultContainer.isV2(data))
        let container = try VaultContainer.parse(data)
        XCTAssertEqual(container.slots[0].count, container.slots[1].count)

        // Повторная разблокировка тем же паролем.
        await store.lock()
        try await store.unlock(masterPassword: "pw")
        got = try await store.items()
        XCTAssertEqual(got, [item])

        // Неверный пароль после миграции.
        await store.lock()
        do {
            try await store.unlock(masterPassword: "bad")
            XCTFail("ожидался неверный пароль")
        } catch let e as VaultError {
            XCTAssertEqual(e, .wrongPassword)
        }
    }
}
