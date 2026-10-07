import XCTest
@testable import StashCore

/// Рантайм-страж локализации (заход 11.1).
///
/// Метки типов документов и полей (`DocumentEditorView.typeName/.fieldLabel`) живут в App-таргете
/// и резолвятся через `Bundle.main` → App/Resources/Localizable.xcstrings. Unit-тест StashCore
/// (standalone, без TEST_HOST) до App-бандла не достаёт, поэтому проверяем ровно тот каталог,
/// который читает рантайм: для каждого case enum'а требуем ключ с переводом en без кириллицы и
/// русским исходником. Плюс сквозная проверка: ни одно значение en во всех каталогах не содержит
/// кириллицы — это ловит утечку перевода в любом enum'е с метками, не только документных.
final class LocalizationCatalogTests: XCTestCase {

    // Каноничные русские метки = ключи каталога. Единый источник — App/DocumentEditorView;
    // здесь дублируем намеренно: тест фиксирует контракт «case → ключ каталога».
    private static let typeLabels: [DocumentType: String] = [
        .passport: "Паспорт", .foreignPassport: "Загранпаспорт", .residencePermit: "ВНЖ",
        .idCard: "ID-карта", .driverLicense: "Водительские права", .insurance: "Страховка",
        .certificate: "Свидетельство", .other: "Документ",
    ]
    private static let fieldLabels: [DocumentFieldKey: String] = [
        .number: "Номер", .fullName: "ФИО", .birthDate: "Дата рождения", .issueDate: "Дата выдачи",
        .issuer: "Кем выдан", .authority: "Орган выдачи", .series: "Серия", .category: "Категория",
        .policyNumber: "Номер полиса", .country: "Страна",
    ]

    private let cyrillic = try! NSRegularExpression(pattern: "[А-Яа-яЁё]")

    private func hasCyrillic(_ s: String) -> Bool {
        cyrillic.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func repoRoot() -> URL {
        // .../StashCoreTests/LocalizationCatalogTests.swift → корень репозитория
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCatalog(_ relative: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["strings"] as! [String: Any]
    }

    /// Значение перевода en для ключа (или nil, если перевода нет). Учитывает "do not translate".
    private func enValue(_ strings: [String: Any], _ key: String) -> String? {
        guard let entry = strings[key] as? [String: Any] else { return nil }
        // Ключ без локализаций и помеченный как не требующий перевода — исходник = сам ключ.
        guard let locs = entry["localizations"] as? [String: Any] else { return nil }
        guard let en = locs["en"] as? [String: Any],
              let unit = en["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String else { return nil }
        return value
    }

    func testDocumentTypeLabelsLocalizedToEnglish() throws {
        let strings = try loadCatalog("App/Resources/Localizable.xcstrings")
        XCTAssertEqual(Self.typeLabels.count, DocumentType.allCases.count,
                       "Добавлен тип документа без метки в тесте")
        for type in DocumentType.allCases {
            let ru = try XCTUnwrap(Self.typeLabels[type], "нет метки для \(type)")
            XCTAssertTrue(hasCyrillic(ru), "исходник (ru) должен быть русским: \(type)")
            let en = try XCTUnwrap(enValue(strings, ru), "нет перевода en для «\(ru)» (\(type))")
            XCTAssertFalse(en.isEmpty, "пустой перевод en для «\(ru)»")
            XCTAssertFalse(hasCyrillic(en), "перевод en содержит кириллицу: «\(ru)» → «\(en)»")
        }
    }

    func testDocumentFieldLabelsLocalizedToEnglish() throws {
        let strings = try loadCatalog("App/Resources/Localizable.xcstrings")
        XCTAssertEqual(Self.fieldLabels.count, DocumentFieldKey.allCases.count,
                       "Добавлено поле документа без метки в тесте")
        for key in DocumentFieldKey.allCases {
            let ru = try XCTUnwrap(Self.fieldLabels[key], "нет метки для \(key)")
            XCTAssertTrue(hasCyrillic(ru), "исходник (ru) должен быть русским: \(key)")
            let en = try XCTUnwrap(enValue(strings, ru), "нет перевода en для «\(ru)» (\(key))")
            XCTAssertFalse(en.isEmpty, "пустой перевод en для «\(ru)»")
            XCTAssertFalse(hasCyrillic(en), "перевод en содержит кириллицу: «\(ru)» → «\(en)»")
        }
    }

    /// Сквозной страж: любой перевод en в любом каталоге без кириллицы.
    func testNoCyrillicInAnyEnglishTranslation() throws {
        for catalog in ["App/Resources/Localizable.xcstrings", "AutoFill/Localizable.xcstrings"] {
            let strings = try loadCatalog(catalog)
            for key in strings.keys {
                guard let en = enValue(strings, key) else { continue }
                XCTAssertFalse(hasCyrillic(en),
                               "\(catalog): перевод en содержит кириллицу для «\(key)» → «\(en)»")
            }
        }
    }
}
