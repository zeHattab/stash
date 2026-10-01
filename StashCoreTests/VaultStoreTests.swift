import XCTest
@testable import StashCore

final class VaultStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(iterations: UInt32 = 1_000) -> (VaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-tests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        let config = VaultStore.Configuration(fileURL: url, kdfIterations: iterations)
        return (VaultStore(configuration: config), url)
    }

    private func sampleLogin(id: UUID = UUID()) -> VaultItem {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return VaultItem(
            id: id,
            kind: .login(username: "alice-unique-xyz",
                         password: "pw-unique-abc-123",
                         urls: ["https://example.com"],
                         totpSecret: "JBSWY3DPEHPK3PXP"),
            title: "Example Login",
            createdAt: date, updatedAt: date, favorite: true, notes: "a note"
        )
    }

    private func readFile(_ url: URL) throws -> VaultFileOnDisk {
        try JSONDecoder().decode(VaultFileOnDisk.self, from: Data(contentsOf: url))
    }

    private func writeFile(_ file: VaultFileOnDisk, to url: URL) throws {
        try JSONEncoder().encode(file).write(to: url)
    }

    private func expectVaultError(
        _ expected: VaultError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("ожидалась ошибка \(expected)", file: file, line: line)
        } catch let error as VaultError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("неожиданная ошибка: \(error)", file: file, line: line)
        }
    }

    // MARK: - Tests

    func testCreateUpsertLockUnlockRoundTrip() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "correct horse battery staple")
        let item = sampleLogin()
        try await store.upsert(item)

        await store.lock()
        let unlocked = await store.isUnlocked
        XCTAssertFalse(unlocked)

        try await store.unlock(masterPassword: "correct horse battery staple")
        let items = try await store.items()
        XCTAssertEqual(items, [item])
    }

    func testUnlockNonexistentThrowsNotFound() async {
        let (store, _) = makeStore()
        await expectVaultError(.notFound) { try await store.unlock(masterPassword: "x") }
    }

    func testWrongPassword() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "right-password")
        await store.lock()
        await expectVaultError(.wrongPassword) {
            try await store.unlock(masterPassword: "wrong-password")
        }
    }

    func testTamperedCiphertextThrowsCorrupted() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "pw")
        try await store.upsert(sampleLogin())
        await store.lock()

        var file = try readFile(url)
        var ct = file.ciphertext
        ct[ct.startIndex] ^= 0xFF
        file.ciphertext = ct
        try writeFile(file, to: url)

        await expectVaultError(.corrupted) { try await store.unlock(masterPassword: "pw") }
    }

    func testTamperedHeaderNeverDecrypts() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "pw")
        try await store.upsert(sampleLogin())
        await store.lock()

        var file = try readFile(url)
        var header = try JSONDecoder().decode(VaultHeader.self, from: file.header)
        var wrapped = header.wrappedVaultKey
        wrapped[wrapped.startIndex] ^= 0xFF
        header.wrappedVaultKey = wrapped
        file.header = try JSONEncoder().encode(header)
        try writeFile(file, to: url)

        do {
            try await store.unlock(masterPassword: "pw")
            XCTFail("подменённый заголовок не должен расшифровываться")
        } catch let error as VaultError {
            XCTAssertTrue(error == .wrongPassword || error == .corrupted,
                          "ожидали wrongPassword или corrupted, получили \(error)")
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testTwoSavesProduceDifferentCiphertext() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "pw")
        let item = sampleLogin(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        try await store.upsert(item)
        let data1 = try Data(contentsOf: url)
        try await store.upsert(item) // те же данные — должен смениться nonce
        let data2 = try Data(contentsOf: url)
        XCTAssertNotEqual(data1, data2)

        let items = try await store.items()
        XCTAssertEqual(items.count, 1)
    }

    func testChangeMasterPassword() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "old-password")
        let item = sampleLogin(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        try await store.upsert(item)

        try await store.changeMasterPassword(old: "old-password", new: "new-password")
        await store.lock()

        await expectVaultError(.wrongPassword) {
            try await store.unlock(masterPassword: "old-password")
        }

        try await store.unlock(masterPassword: "new-password")
        let items = try await store.items()
        XCTAssertEqual(items, [item])
    }

    func testChangeMasterPasswordWithWrongOldThrows() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "old-password")
        try await store.upsert(sampleLogin())
        await expectVaultError(.wrongPassword) {
            try await store.changeMasterPassword(old: "not-the-old", new: "whatever")
        }
    }

    func testUnsupportedVersion() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "pw")
        await store.lock()

        var file = try readFile(url)
        var header = try JSONDecoder().decode(VaultHeader.self, from: file.header)
        header.formatVersion = 999
        file.header = try JSONEncoder().encode(header)
        try writeFile(file, to: url)

        await expectVaultError(.unsupportedVersion(999)) {
            try await store.unlock(masterPassword: "pw")
        }
    }

    func testNoPlaintextOnDisk() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "pw")
        try await store.upsert(sampleLogin())

        let bytes = try Data(contentsOf: url)
        for needle in ["alice-unique-xyz", "pw-unique-abc-123", "JBSWY3DPEHPK3PXP"] {
            XCTAssertNil(bytes.range(of: Data(needle.utf8)),
                         "в файле найден открытый текст: \(needle)")
        }
    }

    func testDeleteAndUpsertDoNotDuplicate() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "pw")
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        var item = VaultItem(id: id, kind: .secureNote, title: "A")
        try await store.upsert(item)
        var items = try await store.items()
        XCTAssertEqual(items.count, 1)

        item.title = "B"
        try await store.upsert(item) // обновление того же id
        items = try await store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "B")

        try await store.delete(id: id)
        items = try await store.items()
        XCTAssertEqual(items.count, 0)
    }

    func testDocumentItemRoundTrip() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "pw")
        let date = Date(timeIntervalSince1970: 1_700_000_500)
        let attachment = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let item = VaultItem(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            kind: .document(type: .passport,
                            fields: ["number": "123456789", "country": "GE"],
                            expiresAt: date,
                            attachmentIDs: [attachment]),
            title: "Passport",
            createdAt: date, updatedAt: date
        )
        try await store.upsert(item)
        await store.lock()
        try await store.unlock(masterPassword: "pw")
        let restored = try await store.items()
        XCTAssertEqual(restored, [item])
    }
}
