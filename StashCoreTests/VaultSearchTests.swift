import XCTest
@testable import StashCore

final class VaultSearchTests: XCTestCase {

    private func login(title: String, user: String = "", urls: [String] = [], notes: String = "") -> VaultItem {
        VaultItem(kind: .login(username: user, password: "x", urls: urls, totpSecret: nil),
                  title: title, notes: notes)
    }

    func testNormalizeFoldsCaseDiacriticsAndYo() {
        XCTAssertEqual(VaultSearch.normalize("Ёлка"), "елка")
        XCTAssertEqual(VaultSearch.normalize("ёжик"), "ежик")
        XCTAssertEqual(VaultSearch.normalize("CafÉ"), "cafe")
        XCTAssertEqual(VaultSearch.normalize("ПРИВЕТ"), "привет")
    }

    func testDomainExtraction() {
        XCTAssertEqual(VaultSearch.domain(from: "https://www.example.com/login"), "example.com")
        XCTAssertEqual(VaultSearch.domain(from: "example.com"), "example.com")
        XCTAssertEqual(VaultSearch.domain(from: "http://sub.site.co.uk/x?y=1"), "sub.site.co.uk")
        XCTAssertNil(VaultSearch.domain(from: "   "))
    }

    func testMatchByTitleUsernameDomainNotes() {
        let item = login(title: "Моя Почта", user: "alice", urls: ["https://mail.example.com"], notes: "рабочий ящик")
        XCTAssertTrue(VaultSearch.matches(item, query: "почта"))
        XCTAssertTrue(VaultSearch.matches(item, query: "ALICE"))
        XCTAssertTrue(VaultSearch.matches(item, query: "example.com"))
        XCTAssertTrue(VaultSearch.matches(item, query: "рабочий"))
        XCTAssertFalse(VaultSearch.matches(item, query: "банк"))
    }

    func testYoInsensitiveMatch() {
        let item = login(title: "Самолёт")
        XCTAssertTrue(VaultSearch.matches(item, query: "самолет"))
        XCTAssertTrue(VaultSearch.matches(item, query: "Самолёт"))
    }

    func testEmptyQueryReturnsAll() {
        let items = [login(title: "A"), login(title: "B")]
        XCTAssertEqual(VaultSearch.filter(items, query: "   ").count, 2)
    }

    func testNoteSearch() {
        let note = VaultItem(kind: .secureNote, title: "Заметка", notes: "секретный код 4815")
        XCTAssertTrue(VaultSearch.matches(note, query: "4815"))
    }
}
