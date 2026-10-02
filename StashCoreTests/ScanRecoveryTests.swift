import XCTest
@testable import StashCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Нормализация изображения скана

final class DocumentImageTests: XCTestCase {

    func testTargetPixelSizeDownscaleKeepsAspect() {
        let t = DocumentImage.targetPixelSize(CGSize(width: 3000, height: 4000), maxSide: 2500)
        XCTAssertEqual(t.height, 2500, accuracy: 0.5)
        XCTAssertEqual(t.width, 1875, accuracy: 0.5) // 3000 * 2500/4000
    }

    func testTargetPixelSizeNoUpscaleForSmall() {
        let t = DocumentImage.targetPixelSize(CGSize(width: 1200, height: 1600), maxSide: 2500)
        XCTAssertEqual(t, CGSize(width: 1200, height: 1600))
    }

    #if canImport(UIKit)
    func testNormalizedLongSideIs2500AndScale1() {
        let img = Self.solid(3000, 4000)
        let norm = DocumentImage.normalized(img, maxSide: 2500)
        XCTAssertEqual(max(norm.pixelSize.width, norm.pixelSize.height), 2500, accuracy: 0.5)
        // scale == 1 → пиксели битмапа совпадают с заявленным размером (не ×screenScale)
        XCTAssertEqual(norm.image.size.width * norm.image.scale, norm.pixelSize.width, accuracy: 0.5)
        XCTAssertEqual(norm.image.scale, 1, accuracy: 0.001)
    }

    func testNormalizedNoUpscaleForSmall() {
        let img = Self.solid(1200, 1600)
        let norm = DocumentImage.normalized(img, maxSide: 2500)
        XCTAssertEqual(norm.pixelSize, CGSize(width: 1200, height: 1600))
    }

    private static func solid(_ w: CGFloat, _ h: CGFloat) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    #endif
}

// MARK: - Устойчивое распознавание MRZ

final class MRZRecoveryTests: XCTestCase {

    private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let cleanTD3 = [
        "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
        "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
    ]
    private let cleanTD1 = [
        "I<UTOD231458907<<<<<<<<<<<<<<<",
        "7408122F1204159UTO<<<<<<<<<<<6",
        "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
    ]

    func testCleanTD3Recovers() throws {
        let (r, diag) = MRZParser.parseRecovering(lines: cleanTD3)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "L898902C3")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
        XCTAssertEqual(res.expiryDate, utc(2012, 4, 15))
        XCTAssertEqual(diag.detectedFormat, "td3")
        XCTAssertTrue(diag.recovered)
    }

    func testOCRErrorsTD3Recover() throws {
        // O↔0, I↔1, S↔5, B↔8, «→< ; имена-строка с «кавычками-заполнителями».
        let lines = [
            "P<UTOERIKSSON<<ANNA<MARIA«««««««««««««««««««",
            "LB9B9O2C36UTO74OB122F12O4IS9ZE184226B<<<<<10",
        ]
        let (r, _) = MRZParser.parseRecovering(lines: lines)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "L898902C3")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
        XCTAssertEqual(res.expiryDate, utc(2012, 4, 15))
    }

    func testNoiseLinesIgnored() throws {
        let lines = ["RUS PASSPORT", "123", cleanTD3[0], cleanTD3[1], "FOOTER"]
        let (r, _) = MRZParser.parseRecovering(lines: lines)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "L898902C3")
    }

    func testReversedLineOrderStillParses() throws {
        let (r, _) = MRZParser.parseRecovering(lines: [cleanTD3[1], cleanTD3[0]])
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
    }

    func testUnrecoverableDoesNotFill() {
        // Несводимый символ в дате рождения — восстановить нельзя.
        var data = Array(cleanTD3[1])
        data[17] = "X"
        let (r, diag) = MRZParser.parseRecovering(lines: [cleanTD3[0], String(data)])
        XCTAssertNil(r)
        XCTAssertEqual(diag.detectedFormat, "td3")
        XCTAssertFalse(diag.recovered)
    }

    func testCleanTD1Recovers() throws {
        let (r, diag) = MRZParser.parseRecovering(lines: cleanTD1)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "D23145890")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
        XCTAssertEqual(diag.detectedFormat, "td1")
    }

    func testOCRErrorsTD1Recover() throws {
        let lines = [
            "I<UTOD231458907<<<<<<<<<<<<<<<",
            "74O8I22FI2O4IS9UTO<<<<<<<<<<<6",
            "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
        ]
        let (r, _) = MRZParser.parseRecovering(lines: lines)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "D23145890")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
        XCTAssertEqual(res.expiryDate, utc(2012, 4, 15))
    }

    func testEmptyInputReturnsNil() {
        let (r, diag) = MRZParser.parseRecovering(lines: [])
        XCTAssertNil(r)
        XCTAssertEqual(diag.candidateLineCount, 0)
    }
}
