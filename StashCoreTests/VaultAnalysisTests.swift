import XCTest
@testable import StashCore

final class VaultAnalysisTests: XCTestCase {

    private func login(_ id: UUID, pw: String) -> VaultItem {
        VaultItem(id: id, kind: .login(username: "u", password: pw, urls: [], totpSecret: nil), title: "t")
    }

    func testReuseCountCountsOtherItemsWithSamePassword() {
        let a = UUID(), b = UUID(), c = UUID()
        let items = [login(a, pw: "shared"), login(b, pw: "shared"), login(c, pw: "unique")]
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: a, in: items), 1)
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: b, in: items), 1)
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: c, in: items), 0)
    }

    func testReuseCountIgnoresEmptyPasswords() {
        let a = UUID(), b = UUID()
        let items = [login(a, pw: ""), login(b, pw: "")]
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: a, in: items), 0)
    }

    func testReuseCountIgnoresNonLogins() {
        let a = UUID(), b = UUID()
        let items = [
            login(a, pw: "shared"),
            VaultItem(id: b, kind: .secureNote, title: "note"),
        ]
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: a, in: items), 0)
    }

    func testThreeWayReuse() {
        let ids = [UUID(), UUID(), UUID()]
        let items = ids.map { login($0, pw: "same") }
        XCTAssertEqual(VaultAnalysis.reuseCount(ofItemID: ids[0], in: items), 2)
    }
}
