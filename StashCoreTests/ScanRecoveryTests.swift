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

    func testBottomBandRect() {
        let r = DocumentImage.bottomBandRect(CGSize(width: 1000, height: 2000), fraction: 0.22)
        XCTAssertEqual(r.width, 1000)
        XCTAssertEqual(r.height, 440)        // 2000 * 0.22
        XCTAssertEqual(r.minY, 1560)         // нижняя полоса
        XCTAssertEqual(r.maxY, 2000)
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
        // Ошибки в ДАТАХ (O→0, I→1, S→5, B→8 — однозначно сводятся к цифрам) и «→<
        // в строке имён. Номер прочитан верно; составная подтверждает корректность.
        let lines = [
            "P<UTOERIKSSON<<ANNA<MARIA«««««««««««««««««««",
            "L898902C36UTO74O8I22FI2O4IS9ZE184226B<<<<<10",
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
        XCTAssertFalse(diag.recovered)
        XCTAssertTrue(diag.attempts.contains { $0.hasPrefix("td3") && $0.contains("fail") })
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

    // Заход 7.4: стык фрагментов ПЕРЕД датами + потеря '<' в хвосте доп. поля.
    // Старый код клал недостающие '<' на стык (перед датой) → дата рождения сдвигалась и
    // КЦ не сходилась. Новый перебирает позиции вставки и находит верное размещение.
    func testTD3SplitBeforeDatesRecovers() throws {
        let data = ["L898902C36", "UTO7408122F1204159ZE184226B", "10"] // потеряны 5 '<' в хвосте
        let names = ["P<UTOERIKSSON<<ANNA<MARIA"]
        let (r, diag) = MRZParser.parseRecovering(rows: [names, data], prefer: .td3)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "L898902C3")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
        XCTAssertEqual(res.expiryDate, utc(2012, 4, 15))
        XCTAssertEqual(diag.detectedFormat, "td3")
    }

    func testTD3ExtraCharRecovers() throws {
        // Лишний символ в хвосте — удаляется перебором.
        let data = ["L898902C36UTO7408122F1204159ZE184226B<<<<<10X"]
        let (r, _) = MRZParser.parseRecovering(rows: [["P<UTOERIKSSON<<ANNA<MARIA"], data], prefer: .td3)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.documentNumber, "L898902C3")
        XCTAssertEqual(res.birthDate, utc(1974, 8, 12))
    }

    // Загранпаспорт — TD3; не должен ошибочно опознаваться как TD1.
    func testTD3PreferredNotMisreadAsTD1() throws {
        // Склеенные строки TD3 (44) — единственный валидный формат.
        let (r, diag) = MRZParser.parseRecovering(lines: cleanTD3, prefer: .td3)
        let res = try XCTUnwrap(r)
        XCTAssertEqual(res.format, .td3)
        XCTAssertEqual(diag.detectedFormat, "td3")
        XCTAssertEqual(res.documentNumber, "L898902C3")
    }
}

// MARK: - Склейка фрагментов MRZ по геометрии

final class MRZLineAssemblerTests: XCTestCase {

    // Один фрагмент на строке — вертикальный центр примерно y, высота h.
    private func frag(_ text: String, x0: Double, x1: Double, y: Double, h: Double = 0.02) -> MRZFragment {
        MRZFragment(text: text, minX: x0, maxX: x1, minY: y - h / 2, maxY: y + h / 2)
    }

    func testGroupsRowPiecesAndCountsJoins() {
        // Строка TD3-данных разбита на 2 куска с разрывом (Vision рвёт на <<<<).
        let frags = [
            frag("L898902C36UTO7408122F1204159ZE184226B", x0: 0.05, x1: 0.70, y: 0.12),
            frag("10", x0: 0.93, x1: 0.97, y: 0.12), // хвост после серии <<<<<
            frag("P<UTOERIKSSON<<ANNA<MARIA", x0: 0.05, x1: 0.55, y: 0.17),
        ]
        let asm = MRZLineAssembler.assemble(frags)
        XCTAssertEqual(asm.rows.count, 2)              // два ряда MRZ
        XCTAssertGreaterThanOrEqual(asm.joins, 1)      // ряд данных склеен из двух кусков
        let dataRow = asm.rows.first { $0.first?.hasPrefix("L8989") == true }
        XCTAssertEqual(dataRow?.count, 2)              // два куска в ряду данных
    }

    func testAssembledTD3FragmentsParse() throws {
        // Нижняя часть страницы: мусорная строка сверху + TD3 двумя рядами, нижний ряд
        // в двух фрагментах с разрывом на заполнителях.
        let frags = [
            frag("ROSSIYSKAYA FEDERATSIYA", x0: 0.1, x1: 0.9, y: 0.30),
            frag("P<UTOERIKSSON<<ANNA<MARIA", x0: 0.05, x1: 0.56, y: 0.17),
            frag("L898902C36UTO7408122F1204159ZE184226B", x0: 0.05, x1: 0.70, y: 0.12),
            frag("10", x0: 0.93, x1: 0.97, y: 0.12),
        ]
        let asm = MRZLineAssembler.assemble(frags)
        let (r, diag) = MRZParser.parseRecovering(rows: asm.rows, prefer: .td3)
        let res = try XCTUnwrap(r)
        XCTAssertTrue(res.checkDigitsValid)
        XCTAssertEqual(res.format, .td3)
        XCTAssertEqual(res.documentNumber, "L898902C3")
        XCTAssertEqual(res.surname, "ERIKSSON")
        XCTAssertEqual(res.birthDate, utc1974812())
        XCTAssertEqual(diag.detectedFormat, "td3")
    }

    func testDoesNotMergeDistinctRows() {
        let frags = [
            frag("AAAAAAAAAA", x0: 0.1, x1: 0.5, y: 0.20),
            frag("BBBBBBBBBB", x0: 0.1, x1: 0.5, y: 0.10),
        ]
        let asm = MRZLineAssembler.assemble(frags)
        XCTAssertEqual(asm.rows.count, 2)
    }

    private func utc1974812() -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 1974, month: 8, day: 12))!
    }
}
