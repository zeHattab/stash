import XCTest
@testable import StashCore

final class PasswordGeneratorTests: XCTestCase {

    func testLengthHonoredAndClamped() throws {
        XCTAssertEqual(try PasswordGenerator.generate(.init(length: 20)).count, 20)
        XCTAssertEqual(try PasswordGenerator.generate(.init(length: 3)).count, PasswordGenerator.minLength)
        XCTAssertEqual(try PasswordGenerator.generate(.init(length: 999)).count, PasswordGenerator.maxLength)
    }

    func testContainsEachEnabledClass() throws {
        let pw = try PasswordGenerator.generate(.init(length: 24,
            useUppercase: true, useLowercase: true, useDigits: true, useSymbols: true))
        XCTAssertTrue(pw.contains { $0.isLowercase })
        XCTAssertTrue(pw.contains { $0.isUppercase })
        XCTAssertTrue(pw.contains { $0.isNumber })
        XCTAssertTrue(pw.contains { !$0.isLetter && !$0.isNumber })
    }

    func testOnlyLowercase() throws {
        let pw = try PasswordGenerator.generate(.init(length: 30,
            useUppercase: false, useLowercase: true, useDigits: false, useSymbols: false))
        XCTAssertTrue(pw.allSatisfy { $0.isLowercase })
    }

    func testExcludeSimilarRemovesConfusableCharacters() throws {
        let confusable: Set<Character> = ["0", "O", "o", "1", "l", "I"]
        for _ in 0..<50 {
            let pw = try PasswordGenerator.generate(.init(length: 64,
                useUppercase: true, useLowercase: true, useDigits: true, useSymbols: true,
                excludeSimilar: true))
            XCTAssertFalse(pw.contains { confusable.contains($0) })
        }
    }

    func testNoCharacterClassThrows() {
        XCTAssertThrowsError(try PasswordGenerator.generate(.init(length: 20,
            useUppercase: false, useLowercase: false, useDigits: false, useSymbols: false))) { error in
            XCTAssertEqual(error as? PasswordGeneratorError, .noCharacterClass)
        }
    }

    func testRoughUniformityOverLargeSample() throws {
        var counts: [Character: Int] = [:]
        for _ in 0..<300 {
            for ch in try PasswordGenerator.generate(.init(length: 40)) {
                counts[ch, default: 0] += 1
            }
        }
        // Пул ~85 символов; на 12000 символов должно появиться большинство из них.
        XCTAssertGreaterThan(counts.keys.count, 60)
        // Ни один символ не должен доминировать (грубая, нехрупкая проверка).
        let total = counts.values.reduce(0, +)
        let maxShare = Double(counts.values.max() ?? 0) / Double(total)
        XCTAssertLessThan(maxShare, 0.1)
    }

    func testRandomIndexWithinBounds() throws {
        for _ in 0..<1000 {
            let i = try PasswordGenerator.randomIndex(10)
            XCTAssertTrue((0..<10).contains(i))
        }
    }
}
