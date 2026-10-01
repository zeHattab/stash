import XCTest
@testable import StashCore

final class PasswordStrengthTests: XCTestCase {

    func testCommonPasswordIsVeryWeak() {
        let a = PasswordEvaluator.assess("password")
        XCTAssertTrue(a.isCommon)
        XCTAssertEqual(a.strength, .veryWeak)
    }

    func testCommonPasswordCaseInsensitive() {
        XCTAssertTrue(PasswordEvaluator.assess("PassWord").isCommon)
        XCTAssertTrue(PasswordEvaluator.assess("QWERTY").isCommon)
    }

    func testShortPasswordDoesNotMeetMinimum() {
        let a = PasswordEvaluator.assess("abc12")
        XCTAssertFalse(a.meetsMinimumLength)
        XCTAssertLessThanOrEqual(a.strength, .weak)
    }

    func testTenCharactersMeetMinimum() {
        XCTAssertTrue(PasswordEvaluator.assess("abcde12345").meetsMinimumLength)
    }

    func testRepeatedCharactersAreWeak() {
        let a = PasswordEvaluator.assess("aaaaaaaaaaaa")
        XCTAssertFalse(a.isCommon)
        XCTAssertLessThanOrEqual(a.strength, .weak)
    }

    func testLongDiversePasswordIsStrong() {
        let a = PasswordEvaluator.assess("Tr0ub4dour&3-Explain!")
        XCTAssertFalse(a.isCommon)
        XCTAssertGreaterThanOrEqual(a.strength, .strong)
        XCTAssertTrue(a.meetsMinimumLength)
    }

    func testPassphraseIsAtLeastFair() {
        let a = PasswordEvaluator.assess("correct horse battery staple")
        XCTAssertGreaterThanOrEqual(a.strength, .fair)
    }

    func testStrengthMonotonicWithComplexity() {
        let weak = PasswordEvaluator.assess("aaaaaaaaaa")
        let strong = PasswordEvaluator.assess("aA1!xQ9#mZ7%")
        XCTAssertLessThan(weak.strength, strong.strength)
    }
}
