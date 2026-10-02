import XCTest
@testable import StashCore

final class DomainMatchTests: XCTestCase {

    func testHostExtraction() {
        XCTAssertEqual(DomainMatch.host(from: "https://accounts.google.com/signin"), "accounts.google.com")
        XCTAssertEqual(DomainMatch.host(from: "google.com"), "google.com")
        XCTAssertEqual(DomainMatch.host(from: "www.google.com"), "google.com")
    }

    func testSubdomainMatches() {
        XCTAssertTrue(DomainMatch.hostsMatch(request: "accounts.google.com", stored: "google.com"))
        XCTAssertTrue(DomainMatch.hostsMatch(request: "google.com", stored: "google.com"))
        XCTAssertTrue(DomainMatch.hostsMatch(request: "google.com", stored: "accounts.google.com"))
    }

    func testNoFalseMatch() {
        XCTAssertFalse(DomainMatch.hostsMatch(request: "evilgoogle.com", stored: "google.com"))
        XCTAssertFalse(DomainMatch.hostsMatch(request: "google.com.evil.com", stored: "google.com"))
        XCTAssertFalse(DomainMatch.hostsMatch(request: "notgoogle.com", stored: "google.com"))
    }

    func testMatchesAgainstURLs() {
        let urls = ["https://accounts.google.com", "mail.google.com"]
        XCTAssertTrue(DomainMatch.matches(serviceIdentifier: "google.com", urls: urls))
        XCTAssertTrue(DomainMatch.matches(serviceIdentifier: "https://accounts.google.com/x", urls: urls))
        XCTAssertFalse(DomainMatch.matches(serviceIdentifier: "evilgoogle.com", urls: urls))
        XCTAssertFalse(DomainMatch.matches(serviceIdentifier: "apple.com", urls: urls))
    }
}

final class CredentialIdentityPlanTests: XCTestCase {

    private func login(_ title: String, user: String, urls: [String]) -> VaultItem {
        VaultItem(kind: .login(username: user, password: "p", urls: urls, totpSecret: nil), title: title)
    }

    func testEntriesWhenEnabled() {
        let items = [login("Google", user: "me@gmail.com", urls: ["https://accounts.google.com", "mail.google.com"])]
        let e = CredentialIdentityPlan.entries(items: items, hintsEnabled: true,
                                               secondPasswordEnabled: false, isDecoySession: false)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first?.domain, "accounts.google.com")
        XCTAssertEqual(e.first?.user, "me@gmail.com")
    }

    func testEmptyWhenHintsOff() {
        let items = [login("G", user: "u", urls: ["google.com"])]
        XCTAssertTrue(CredentialIdentityPlan.entries(items: items, hintsEnabled: false,
                                                     secondPasswordEnabled: false, isDecoySession: false).isEmpty)
    }

    func testEmptyWhenSecondPassword() {
        let items = [login("G", user: "u", urls: ["google.com"])]
        XCTAssertTrue(CredentialIdentityPlan.entries(items: items, hintsEnabled: true,
                                                     secondPasswordEnabled: true, isDecoySession: false).isEmpty)
    }

    func testEmptyInDecoySession() {
        let items = [login("G", user: "u", urls: ["google.com"])]
        XCTAssertTrue(CredentialIdentityPlan.entries(items: items, hintsEnabled: true,
                                                     secondPasswordEnabled: false, isDecoySession: true).isEmpty)
    }

    func testUsesTitleWhenNoUsername() {
        let items = [login("MyBank", user: "", urls: ["bank.example"])]
        let e = CredentialIdentityPlan.entries(items: items, hintsEnabled: true,
                                               secondPasswordEnabled: false, isDecoySession: false)
        XCTAssertEqual(e.first?.user, "MyBank")
    }
}
