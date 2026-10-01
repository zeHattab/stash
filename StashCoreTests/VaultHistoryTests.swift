import XCTest
@testable import StashCore

final class VaultHistoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func login(pw: String, history: [PasswordHistoryEntry]? = nil) -> VaultItem {
        VaultItem(kind: .login(username: "u", password: pw, urls: [], totpSecret: nil),
                  title: "t", passwordHistory: history)
    }

    func testPasswordChangeAppendsOldPassword() {
        let previous = login(pw: "old")
        let updated = login(pw: "new")
        let result = VaultHistory.applyingPasswordChange(previous: previous, updated: updated, now: t0)
        XCTAssertEqual(result.passwordHistory?.count, 1)
        XCTAssertEqual(result.passwordHistory?.first?.password, "old")
        XCTAssertEqual(result.passwordHistory?.first?.changedAt, t0)
    }

    func testSamePasswordDoesNotAppend() {
        let result = VaultHistory.applyingPasswordChange(previous: login(pw: "x"), updated: login(pw: "x"), now: t0)
        XCTAssertNil(result.passwordHistory)
    }

    func testNilPreviousDoesNotAppend() {
        let result = VaultHistory.applyingPasswordChange(previous: nil, updated: login(pw: "x"), now: t0)
        XCTAssertNil(result.passwordHistory)
    }

    func testEmptyOldPasswordNotRecorded() {
        let result = VaultHistory.applyingPasswordChange(previous: login(pw: ""), updated: login(pw: "new"), now: t0)
        XCTAssertNil(result.passwordHistory)
    }

    func testHistoryCappedAtTen() {
        var history = (0..<10).map { PasswordHistoryEntry(password: "p\($0)", changedAt: t0) }
        var updated = login(pw: "newest")
        updated.passwordHistory = history
        let result = VaultHistory.applyingPasswordChange(previous: login(pw: "prev"), updated: updated, now: t0)
        XCTAssertEqual(result.passwordHistory?.count, 10)
        XCTAssertEqual(result.passwordHistory?.first?.password, "prev") // новейший сверху
        history = result.passwordHistory ?? []
        XCTAssertFalse(history.contains { $0.password == "p9" }) // самый старый вытеснен
    }
}
