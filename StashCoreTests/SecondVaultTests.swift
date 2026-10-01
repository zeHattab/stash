import XCTest
import CryptoKit
@testable import StashCore

final class SecondVaultTests: XCTestCase {

    private func makeStore() -> (VaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-2nd-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        return (VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000)), url)
    }

    private func login(_ title: String, pw: String) -> VaultItem {
        VaultItem(kind: .login(username: "u", password: pw, urls: [], totpSecret: nil), title: title)
    }

    private func samples() -> [VaultItem] {
        [login("Decoy1", pw: "d1"), login("Decoy2", pw: "d2")]
    }

    private func expect(_ expected: VaultError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("ожидалась \(expected)") }
        catch let e as VaultError { XCTAssertEqual(e, expected) }
        catch { XCTFail("неожиданная ошибка \(error)") }
    }

    func testBothPasswordsOpenOwnVaults() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master-pass-1")
        let real = login("RealBank", pw: "real-secret")
        try await store.upsert(real)
        try await store.enableSecondVault(secondPassword: "decoy-pass-2", sampleItems: samples())

        await store.lock()
        try await store.unlock(masterPassword: "master-pass-1")
        var opened = try await store.items()
        XCTAssertEqual(opened, [real])
        var decoy = await store.currentIsDecoy()
        var second = await store.currentSecondPasswordEnabled()
        XCTAssertFalse(decoy)
        XCTAssertTrue(second)

        await store.lock()
        try await store.unlock(masterPassword: "decoy-pass-2")
        opened = try await store.items()
        XCTAssertEqual(opened.map(\.title), ["Decoy1", "Decoy2"])
        decoy = await store.currentIsDecoy()
        second = await store.currentSecondPasswordEnabled()
        XCTAssertTrue(decoy)
        XCTAssertFalse(second)
    }

    func testSecondPasswordMustDiffer() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "same-pass")
        await expect(.secondPasswordMustDiffer) {
            try await store.enableSecondVault(secondPassword: "same-pass", sampleItems: self.samples())
        }
    }

    func testSlotsSameSizeRegardlessOfData() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "m")
        for i in 0..<30 { try await store.upsert(login("Item\(i)", pw: "p\(i)")) }
        let c = try VaultContainerV4.parse(Data(contentsOf: url))
        XCTAssertEqual(c.slots[0].count, c.slots[1].count)
        XCTAssertEqual(c.slots[0].count, c.slotSize)
    }

    func testUnusedSlotLooksRandom() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "m")
        let c = try VaultContainerV4.parse(Data(contentsOf: url))
        for slot in c.slots {
            // И занятый (шифротекст), и пустой (случайный) слот — высокое разнообразие байтов.
            XCTAssertGreaterThan(Set(slot).count, 200)
        }
    }

    func testRealVaultRandomPosition() async throws {
        var seen: Set<Int> = []
        for _ in 0..<30 {
            let (store, _) = makeStore()
            try await store.create(masterPassword: "m")
            if let idx = await store.openedSlotForTesting() { seen.insert(idx) }
        }
        XCTAssertEqual(seen, [0, 1], "настоящий сейф должен попадать в оба слота")
    }

    func testDecoyOperationsNeverChangeRealSlot() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.upsert(login("Real", pw: "secret"))
        try await store.enableSecondVault(secondPassword: "decoy", sampleItems: samples())

        // Узнаём индекс настоящего слота и сохраняем его байты.
        await store.lock()
        try await store.unlock(masterPassword: "master")
        let openedIndex = await store.openedSlotForTesting()
        let realIndex = try XCTUnwrap(openedIndex)
        let before = try VaultContainerV4.parse(Data(contentsOf: url)).slots[realIndex]

        // Все возможные операции из ложного сейфа.
        await store.lock()
        try await store.unlock(masterPassword: "decoy")
        try await store.setSecondPasswordFlag(true)
        try await store.setSecondPasswordFlag(false)
        try await store.changeMasterPassword(old: "decoy", new: "decoy2")
        for item in try await store.items() { try await store.delete(id: item.id) }

        let after = try VaultContainerV4.parse(Data(contentsOf: url)).slots[realIndex]
        XCTAssertEqual(before, after, "операции из ложного сейфа не должны менять настоящий слот")

        // Настоящий сейф по-прежнему открывается мастер-паролем.
        await store.lock()
        try await store.unlock(masterPassword: "master")
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["Real"])
    }

    func testDisableWipesSecondSlot() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.enableSecondVault(secondPassword: "decoy", sampleItems: samples())

        await store.lock()
        try await store.unlock(masterPassword: "master")
        try await store.disableSecondVault(masterPassword: "master")

        await store.lock()
        await expect(.wrongPassword) { try await store.unlock(masterPassword: "decoy") }

        await store.lock()
        try await store.unlock(masterPassword: "master")
        let stillEnabled = await store.currentSecondPasswordEnabled()
        XCTAssertFalse(stillEnabled)
    }

    func testWrongPasswordWithSecondEnabled() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.enableSecondVault(secondPassword: "decoy", sampleItems: samples())
        await store.lock()
        await expect(.wrongPassword) { try await store.unlock(masterPassword: "nope") }
    }

    func testDecoyCreatedEmptyWhenNoItems() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.enableSecondVault(secondPassword: "decoy", sampleItems: []) // без примеров
        await store.lock()
        try await store.unlock(masterPassword: "decoy")
        let items = try await store.items()
        XCTAssertTrue(items.isEmpty)
        let isDecoy = await store.currentIsDecoy()
        XCTAssertTrue(isDecoy)
    }

    func testDecoyNeedsFillingFlagReflectsCount() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.enableSecondVault(secondPassword: "decoy", sampleItems: []) // 0 < 3
        let sparse = await store.currentDecoyNeedsFilling()
        XCTAssertTrue(sparse)

        let (store2, _) = makeStore()
        try await store2.create(masterPassword: "master")
        try await store2.enableSecondVault(
            secondPassword: "decoy",
            sampleItems: [login("a", pw: "1"), login("b", pw: "2"), login("c", pw: "3")])
        let notSparse = await store2.currentDecoyNeedsFilling()
        XCTAssertFalse(notSparse)
    }

    func testSlotGrowsKeepingBothVaults() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.upsert(login("Real", pw: "r"))
        _ = try await store.enableSecondVault(secondPassword: "decoy", sampleItems: [login("DecoyItem", pw: "d")])

        // Рост настоящего сейфа за пределы 256 КБ.
        let big = String(repeating: "a", count: 300_000)
        try await store.unlock(masterPassword: "master")
        try await store.upsert(VaultItem(kind: .secureNote, title: "Big", notes: big))
        let grown = await store.slotSizeForTesting()
        XCTAssertGreaterThan(grown, VaultContainerV4.steps[0])

        // Настоящий сейф цел.
        await store.lock(); try await store.unlock(masterPassword: "master")
        let realItems = try await store.items()
        XCTAssertEqual(realItems.first(where: { $0.title == "Big" })?.notes.count, 300_000)

        // Ложный сейф по-прежнему читается своим ключом (его слот только дополнен случайными).
        await store.lock(); try await store.unlock(masterPassword: "decoy")
        let decoyItems = try await store.items()
        XCTAssertEqual(decoyItems.map(\.title), ["DecoyItem"])
        let isDecoy = await store.currentIsDecoy()
        XCTAssertTrue(isDecoy)
    }

    func testWriteFailureKeepsOldFileIntact() async throws {
        let (store, _) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.upsert(login("First", pw: "1"))

        await store.setSimulateWriteFailureForTesting(true)
        do {
            try await store.upsert(login("Second", pw: "2"))
            XCTFail("ожидалась ошибка записи")
        } catch let e as VaultError {
            XCTAssertEqual(e, .ioError("simulated write failure"))
        }
        await store.setSimulateWriteFailureForTesting(false)

        await store.lock(); try await store.unlock(masterPassword: "master")
        let items = try await store.items()
        XCTAssertEqual(items.map(\.title), ["First"]) // второй не сохранён, файл цел
    }

    func testSlotSizeTooLargeThrows() {
        XCTAssertThrowsError(try VaultContainerV4.slotSize(forCiphertextLength: 600_000_000)) { error in
            XCTAssertEqual(error as? VaultError, .tooLarge)
        }
    }

    func testChangeSecondPasswordKeepsDecoyAndRealUnchanged() async throws {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "master")
        try await store.upsert(login("Real", pw: "r"))
        _ = try await store.enableSecondVault(secondPassword: "old-decoy", sampleItems: [login("DItem", pw: "d")])

        // Байты настоящего слота до смены второго пароля.
        await store.lock(); try await store.unlock(masterPassword: "master")
        let openedIndex = await store.openedSlotForTesting()
        let realIndex = try XCTUnwrap(openedIndex)
        let realBefore = try VaultContainerV4.parse(Data(contentsOf: url)).slots[realIndex]

        try await store.changeSecondPassword(master: "master", newSecond: "new-decoy")

        // Старый второй пароль не открывает, новый открывает, записи ложного целы.
        await store.lock()
        await expect(.wrongPassword) { try await store.unlock(masterPassword: "old-decoy") }
        await store.lock(); try await store.unlock(masterPassword: "new-decoy")
        let dItems = try await store.items()
        XCTAssertEqual(dItems.map(\.title), ["DItem"])

        // Настоящий слот не изменился вовсе (байт-в-байт).
        let realAfter = try VaultContainerV4.parse(Data(contentsOf: url)).slots[realIndex]
        XCTAssertEqual(realBefore, realAfter)
    }
}
