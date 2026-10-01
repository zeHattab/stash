import XCTest
@testable import StashCore

final class SchemaCompatTests: XCTestCase {

    func testLoginWithoutHistoryOmitsKeyAndDecodes() throws {
        let item = VaultItem(kind: .login(username: "u", password: "p", urls: [], totpSecret: nil),
                             title: "t")
        let data = try JSONEncoder().encode(item)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Optional nil → ключ отсутствует (формат совместим со старой схемой).
        XCTAssertFalse(json.contains("passwordHistory"))

        let decoded = try JSONDecoder().decode(VaultItem.self, from: data)
        XCTAssertNil(decoded.passwordHistory)
        XCTAssertEqual(decoded, item)
    }

    func testOldSchemaVersionPayloadDecodes() throws {
        // Полезная нагрузка «прежней версии» (schemaVersion = 1), записи без истории.
        let items = [
            VaultItem(kind: .login(username: "a", password: "b", urls: ["https://x.com"], totpSecret: nil),
                      title: "Login"),
            VaultItem(kind: .secureNote, title: "Note", notes: "text"),
        ]
        let old = VaultPayload(schemaVersion: 1, items: items)
        let data = try JSONEncoder().encode(old)

        let decoded = try JSONDecoder().decode(VaultPayload.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.items, items)
    }

    func testItemWithHistoryRoundTrips() throws {
        let history = [PasswordHistoryEntry(password: "old", changedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let item = VaultItem(kind: .login(username: "u", password: "new", urls: [], totpSecret: nil),
                             title: "t", passwordHistory: history)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(VaultItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.passwordHistory?.count, 1)
    }
}
