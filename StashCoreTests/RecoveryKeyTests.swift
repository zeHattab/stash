import XCTest
@testable import StashCore

final class RecoveryKeyTests: XCTestCase {

    private func makeStore() -> (VaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-rec-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        return (VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000)), url)
    }

    private func login(_ title: String) -> VaultItem {
        VaultItem(kind: .login(username: "u", password: "p", urls: [], totpSecret: nil), title: title)
    }

    private func expect(_ expected: VaultError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("ожидалась \(expected)") }
        catch let e as VaultError { XCTAssertEqual(e, expected) }
        catch { XCTFail("неожиданная ошибка \(error)") }
    }

    func testNormalizeIsCaseSpaceDashInsensitive() {
        let a = RecoveryKey.normalize("abcd-efgh 2345")
        let b = RecoveryKey.normalize("ABCDEFGH2345")
        XCTAssertEqual(a, b)
    }

    func testRecoveryKeyOpensAndResetsMaster() async throws {
        let (store, _) = makeStore()
        let key = try await store.create(masterPassword: "old-master")
        try await store.upsert(login("Bank"))
        await store.lock()

        // Ключ открывает и задаёт новый мастер.
        try await store.recoverWithKey(key, newMasterPassword: "new-master")
        let items = try await store.items()
        XCTAssertEqual(items.map(\.title), ["Bank"])

        await store.lock()
        await expect(.wrongPassword) { try await store.unlock(masterPassword: "old-master") }
        try await store.unlock(masterPassword: "new-master")
        XCTAssertEqual(try await store.items().map(\.title), ["Bank"])
    }

    func testRecoveryKeyNormalizationOnInput() async throws {
        let (store, _) = makeStore()
        let key = try await store.create(masterPassword: "m")
        await store.lock()
        let messy = key.lowercased().replacingOccurrences(of: "-", with: " ")
        try await store.recoverWithKey(messy, newMasterPassword: "brand-new-pass")
        XCTAssertTrue(await store.isUnlocked)
    }

    func testRegenerateInvalidatesOldKey() async throws {
        let (store, _) = makeStore()
        let key1 = try await store.create(masterPassword: "master")
        let key2 = try await store.regenerateRecoveryKey(masterPassword: "master")
        XCTAssertNotEqual(RecoveryKey.normalize(key1), RecoveryKey.normalize(key2))

        await store.lock()
        await expect(.wrongPassword) { try await store.recoverWithKey(key1, newMasterPassword: "x-pass-1") }
        await store.lock()
        try await store.recoverWithKey(key2, newMasterPassword: "x-pass-2")
        XCTAssertTrue(await store.isUnlocked)
    }

    func testDecoyRecoveryKeyIsIsolated() async throws {
        let (store, _) = makeStore()
        let realKey = try await store.create(masterPassword: "master")
        try await store.upsert(login("RealOnly"))
        let decoyKey = try await store.enableSecondVault(
            secondPassword: "decoy-pass",
            sampleItems: [login("DecoyOnly")])

        // Ключ настоящего открывает настоящий (там RealOnly), ключ ложного — ложный.
        await store.lock()
        try await store.recoverWithKey(realKey, newMasterPassword: "nm1")
        XCTAssertEqual(try await store.items().map(\.title), ["RealOnly"])
        XCTAssertFalse(await store.currentIsDecoy())

        await store.lock()
        try await store.recoverWithKey(decoyKey, newMasterPassword: "nm2")
        XCTAssertEqual(try await store.items().map(\.title), ["DecoyOnly"])
        XCTAssertTrue(await store.currentIsDecoy())
    }
}
