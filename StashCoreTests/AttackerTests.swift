import XCTest
@testable import StashCore

/// Тест-«различитель»: атакующий получает файл и, зная формат, пытается определить,
/// занят ли каждый слот. В v3 открытых полей нет, поэтому его точность не отличается
/// от угадывания.
final class AttackerTests: XCTestCase {

    private func makeStore() -> (VaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-atk-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        return (VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000)), url)
    }

    /// Эвристика атакующего по формату v2: читает первые 4 байта как длину (BE) и
    /// считает слот занятым, если это «правдоподобная» длина (0 < L < slotSize).
    private func looksOccupiedByLengthField(_ slot: Data) -> Bool {
        let b = [UInt8](slot)
        guard b.count >= 4 else { return false }
        let L = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        return L > 0 && Int(L) < b.count
    }

    /// Собирает по одному занятому и одному пустому слоту из свежесозданного сейфа.
    private func occupiedAndEmptySlot() async throws -> (occupied: Data, empty: Data) {
        let (store, url) = makeStore()
        try await store.create(masterPassword: "master-pass")
        let realIndex = try XCTUnwrap(await store.openedSlotForTesting())
        let container = try VaultContainerV3.parse(Data(contentsOf: url))
        return (container.slots[realIndex], container.slots[1 - realIndex])
    }

    func testOccupiedSlotHasNoPlausibleLengthField() async throws {
        var occupiedHits = 0
        let n = 60
        for _ in 0..<n {
            let (occupied, _) = try await occupiedAndEmptySlot()
            if looksOccupiedByLengthField(occupied) { occupiedHits += 1 }
        }
        // В v3 первые 4 байта — случайная соль, а не длина: «срабатываний» почти нет.
        XCTAssertLessThan(Double(occupiedHits) / Double(n), 0.2)
    }

    func testAttackerAccuracyNearChance() async throws {
        var occHits = 0, emptyHits = 0
        let n = 60
        for _ in 0..<n {
            let (occupied, empty) = try await occupiedAndEmptySlot()
            if looksOccupiedByLengthField(occupied) { occHits += 1 }
            if looksOccupiedByLengthField(empty) { emptyHits += 1 }
        }
        let occRate = Double(occHits) / Double(n)
        let emptyRate = Double(emptyHits) / Double(n)
        // Точность на занятых и пустых слотах не должна заметно отличаться.
        XCTAssertLessThan(abs(occRate - emptyRate), 0.2)
    }
}
