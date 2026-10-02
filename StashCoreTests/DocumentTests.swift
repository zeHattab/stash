import XCTest
@testable import StashCore

final class DocumentTests: XCTestCase {

    private func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - MRZ (ICAO 9303, вымышленные образцы из спецификации)

    func testMRZTD3Passport() throws {
        let raw = """
        P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
        L898902C36UTO7408122F1204159ZE184226B<<<<<10
        """
        let r = try XCTUnwrap(MRZParser.parse(raw))
        XCTAssertEqual(r.format, .td3)
        XCTAssertTrue(r.checkDigitsValid)
        XCTAssertEqual(r.documentNumber, "L898902C3")
        XCTAssertEqual(r.surname, "ERIKSSON")
        XCTAssertEqual(r.givenNames, "ANNA MARIA")
        XCTAssertEqual(r.nationality, "UTO")
        XCTAssertEqual(r.sex, "F")
        XCTAssertEqual(r.birthDate, utcDate(1974, 8, 12))
        XCTAssertEqual(r.expiryDate, utcDate(2012, 4, 15))
    }

    func testMRZTD1IDCard() throws {
        let raw = """
        I<UTOD231458907<<<<<<<<<<<<<<<
        7408122F1204159UTO<<<<<<<<<<<6
        ERIKSSON<<ANNA<MARIA<<<<<<<<<<
        """
        let r = try XCTUnwrap(MRZParser.parse(raw))
        XCTAssertEqual(r.format, .td1)
        XCTAssertTrue(r.checkDigitsValid)
        XCTAssertEqual(r.documentNumber, "D23145890")
        XCTAssertEqual(r.surname, "ERIKSSON")
        XCTAssertEqual(r.givenNames, "ANNA MARIA")
        XCTAssertEqual(r.birthDate, utcDate(1974, 8, 12))
        XCTAssertEqual(r.expiryDate, utcDate(2012, 4, 15))
    }

    func testMRZBadCheckDigitFlagged() throws {
        // Портим контрольную цифру номера документа (6 → 5).
        let raw = """
        P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
        L898902C35UTO7408122F1204159ZE184226B<<<<<10
        """
        let r = try XCTUnwrap(MRZParser.parse(raw))
        XCTAssertFalse(r.checkDigitsValid) // поля не автозаполнять молча
    }

    func testMRZGarbageReturnsNil() {
        XCTAssertNil(MRZParser.parse("не mrz\nпросто текст"))
    }

    // MARK: - Сроки действия

    func testSoonExpiring() {
        let now = utcDate(2026, 1, 1)
        func doc(_ title: String, _ exp: Date?) -> VaultItem {
            VaultItem(kind: .document(type: .passport, fields: [:], expiresAt: exp, attachmentIDs: []), title: title)
        }
        let items = [
            doc("Past", utcDate(2025, 12, 1)),
            doc("In30", utcDate(2026, 1, 31)),
            doc("In200", utcDate(2026, 7, 20)),
            doc("NoExpiry", nil),
            VaultItem(kind: .secureNote, title: "Note"),
        ]
        let soon = VaultAnalysis.soonExpiring(items, within: 90, now: now)
        XCTAssertEqual(soon.map(\.title), ["Past", "In30"]) // по возрастанию даты, без In200/NoExpiry/Note
    }

    // MARK: - Поля документа

    func testRecommendedFields() {
        XCTAssertTrue(DocumentFields.recommended(for: .passport).contains(.number))
        XCTAssertTrue(DocumentFields.recommended(for: .driverLicense).contains(.category))
        XCTAssertTrue(DocumentFields.recommended(for: .insurance).contains(.policyNumber))
    }
}
