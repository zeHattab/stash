import Foundation

/// Разобранная машиночитаемая зона (MRZ) паспорта/ID по ICAO 9303.
public struct MRZResult: Sendable, Equatable {
    public var format: Format
    public var documentNumber: String
    public var surname: String
    public var givenNames: String
    public var nationality: String
    public var issuingState: String
    public var sex: String
    public var birthDate: Date?
    public var expiryDate: Date?
    /// Все контрольные цифры сошлись. Если false — поля НЕ автозаполнять молча.
    public var checkDigitsValid: Bool

    public enum Format: String, Sendable, Equatable { case td1, td2, td3 }
}

/// Техническая диагностика распознавания MRZ — БЕЗ текста и данных документа.
public struct MRZDiagnostics: Sendable, Equatable {
    public var candidateLineCount: Int
    public var detectedFormat: String?     // "td3" / "td2" / "td1" / nil
    public var failedChecks: [String]      // имена несошедшихся контрольных цифр
    public var recovered: Bool             // удалось ли восстановить до валидности
    public var attempts: [String]          // краткий итог по каждому формату (длины, какие КЦ)
    public init(candidateLineCount: Int = 0, detectedFormat: String? = nil,
                failedChecks: [String] = [], recovered: Bool = false, attempts: [String] = []) {
        self.candidateLineCount = candidateLineCount
        self.detectedFormat = detectedFormat
        self.failedChecks = failedChecks
        self.recovered = recovered
        self.attempts = attempts
    }
}

/// Парсер MRZ TD1 (3×30) и TD3 (2×44) с проверкой контрольных цифр по ICAO 9303.
public enum MRZParser {

    public static func parse(_ raw: String) -> MRZResult? {
        let lines = raw.uppercased()
            .split(whereSeparator: \.isNewline)
            .map { line -> String in String(line.unicodeScalars.filter { allowed($0) }.map(Character.init)) }
            .filter { !$0.isEmpty }

        if let td3 = lines.filter({ $0.count == 44 }).prefix(2).nilIfNotCount(2) {
            return parseTD3(td3[0], td3[1])
        }
        if let td1 = lines.filter({ $0.count == 30 }).prefix(3).nilIfNotCount(3) {
            return parseTD1(td1[0], td1[1], td1[2])
        }
        return nil
    }

    // MARK: - TD3 (паспорт): 2 строки по 44

    static func parseTD3(_ l1: String, _ l2: String) -> MRZResult {
        let a = Array(l1), b = Array(l2)
        let issuingState = String(a[2..<5]).trimmingMRZ()
        let (surname, given) = names(String(a[5..<44]))

        let docNo = String(b[0..<9]).trimmingMRZ()
        let docNoCD = b[9]
        let nationality = String(b[10..<13]).trimmingMRZ()
        let birth = String(b[13..<19]); let birthCD = b[19]
        let sex = String(b[20..<21])
        let expiry = String(b[21..<27]); let expiryCD = b[27]
        let optional = String(b[28..<42]); let optionalCD = b[42]
        let compositeCD = b[43]

        var ok = true
        ok = check(String(b[0..<9]), docNoCD) && ok
        ok = check(birth, birthCD) && ok
        ok = check(expiry, expiryCD) && ok
        ok = check(optional, optionalCD) && ok
        let composite = String(b[0..<10]) + birth + String(birthCD) + expiry + String(expiryCD) + optional + String(optionalCD)
        ok = check(composite, compositeCD) && ok

        return MRZResult(format: .td3, documentNumber: docNo, surname: surname, givenNames: given,
                         nationality: nationality, issuingState: issuingState, sex: normalizeSex(sex),
                         birthDate: date(birth, isExpiry: false), expiryDate: date(expiry, isExpiry: true),
                         checkDigitsValid: ok)
    }

    // MARK: - TD1 (ID-карта): 3 строки по 30

    static func parseTD1(_ l1: String, _ l2: String, _ l3: String) -> MRZResult {
        let a = Array(l1), b = Array(l2), c = Array(l3)
        let issuingState = String(a[2..<5]).trimmingMRZ()
        let docNo = String(a[5..<14]).trimmingMRZ()
        let docNoCD = a[14]
        let optional1 = String(a[15..<30])

        let birth = String(b[0..<6]); let birthCD = b[6]
        let sex = String(b[7..<8])
        let expiry = String(b[8..<14]); let expiryCD = b[14]
        let nationality = String(b[15..<18]).trimmingMRZ()
        let optional2 = String(b[18..<29])
        let compositeCD = b[29]

        let (surname, given) = names(String(c[0..<30]))

        var ok = true
        ok = check(String(a[5..<14]), docNoCD) && ok
        ok = check(birth, birthCD) && ok
        ok = check(expiry, expiryCD) && ok
        let composite = String(a[5..<30]) + birth + String(birthCD) + expiry + String(expiryCD) + optional2
        ok = check(composite, compositeCD) && ok
        _ = optional1

        return MRZResult(format: .td1, documentNumber: docNo, surname: surname, givenNames: given,
                         nationality: nationality, issuingState: issuingState, sex: normalizeSex(sex),
                         birthDate: date(birth, isExpiry: false), expiryDate: date(expiry, isExpiry: true),
                         checkDigitsValid: ok)
    }

    // MARK: - Общие

    private static func allowed(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "<"
    }

    static func charValue(_ ch: Character) -> Int {
        if let d = ch.wholeNumberValue, ch.isNumber { return d }
        if ch == "<" { return 0 }
        if let a = ch.asciiValue, ch.isLetter { return Int(a) - 65 + 10 }
        return 0
    }

    static func checkDigit(_ s: String) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, ch) in s.enumerated() { sum += charValue(ch) * weights[i % 3] }
        return sum % 10
    }

    private static func check(_ field: String, _ digit: Character) -> Bool {
        guard let d = digit.wholeNumberValue, digit.isNumber else { return false }
        return checkDigit(field) == d
    }

    private static func names(_ field: String) -> (surname: String, given: String) {
        let parts = field.components(separatedBy: "<<")
        let surname = (parts.first ?? "").replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        let given = parts.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (surname, given)
    }

    private static func normalizeSex(_ s: String) -> String {
        switch s { case "M": return "M"; case "F": return "F"; default: return "" }
    }

    private static func date(_ yymmdd: String, isExpiry: Bool) -> Date? {
        guard yymmdd.count == 6, let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)), let dd = Int(yymmdd.suffix(2)),
              (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let currentYY = cal.component(.year, from: Date()) % 100
        let century = isExpiry ? 2000 : (yy > currentYY ? 1900 : 2000)
        var comps = DateComponents()
        comps.year = century + yy; comps.month = mm; comps.day = dd
        return cal.date(from: comps)
    }

    // MARK: - Устойчивое распознавание (из «грязного» OCR)

    /// Символы, которые OCR часто ставит вместо заполнителя '<'.
    private static let fillerLookalikes = Set<Character>("«»‹›≪≫＜＞〈〉⟨⟩|¦/\\[](){}*—–‐-_~·•…")

    /// Группы взаимозаменяемых по виду символов (буква ↔ цифра).
    private static let confusionGroups: [Set<Character>] = [
        ["0", "O", "D", "Q"], ["1", "I", "L"], ["2", "Z"], ["5", "S"], ["6", "G"], ["8", "B"]
    ]
    private static func confusionGroup(of ch: Character) -> Set<Character>? {
        confusionGroups.first { $0.contains(ch) }
    }

    /// Нормализует строку-кандидат MRZ: верхний регистр, похожие на '<' → '<',
    /// остальное вне алфавита (пробелы и пр.) выбрасывается.
    public static func normalizeLine(_ raw: String) -> String {
        var out = ""
        for ch in raw.uppercased() {
            if ch.unicodeScalars.count == 1, allowed(ch.unicodeScalars.first!) {
                out.append(ch)
            } else if fillerLookalikes.contains(ch) {
                out.append("<")
            }
        }
        return out
    }

    /// Кандидаты для позиции, где по спецификации должна быть ЦИФРА (оригинал первым).
    private static func digitCandidates(_ ch: Character) -> [Character] {
        if ch.isNumber { return [ch] }
        guard let g = confusionGroup(of: ch) else { return [] }
        return g.filter { $0.isNumber }
    }

    /// Кандидаты для буквенно-цифровой позиции: ОРИГИНАЛ первым (как прочитал OCR), затем
    /// двойники. Если прочитанное уже проходит контрольную — ничего не меняем; подстановка
    /// включается только при несовпадении. Истинные коллизии (оба варианта валидны)
    /// однозначно разрешить нельзя — остаётся прочитанное.
    private static func alnumCandidates(_ ch: Character) -> [Character] {
        if ch == "<" { return ["<"] }
        guard let g = confusionGroup(of: ch) else { return [ch] }
        return [ch] + g.filter { $0 != ch }.sorted()
    }

    /// Значение контрольной цифры из символа (с учётом '<'=0 и похожих на цифры).
    private static func cdValue(_ ch: Character) -> Int? {
        if ch == "<" { return 0 }
        if ch.isNumber { return ch.wholeNumberValue }
        if let g = confusionGroup(of: ch), let d = g.first(where: { $0.isNumber }) { return d.wholeNumberValue }
        return nil
    }

    /// ВСЕ варианты поля (той же длины), у которых сходится контрольная цифра. Перебирает
    /// ограниченный набор альтернатив по неоднозначным символам (оригинал первым).
    static func recoverAll(field: [Character], cdChar: Character, digitsOnly: Bool, cap: Int = 50_000) -> [String] {
        guard let cd = cdValue(cdChar) else { return [] }
        let perPos: [[Character]] = field.map { digitsOnly ? digitCandidates($0) : alnumCandidates($0) }
        if perPos.contains(where: { $0.isEmpty }) { return [] }
        let total = perPos.reduce(1) { $0 * $1.count }
        guard total > 0 else { return [] }
        if total > cap {
            let norm = String(perPos.map { $0[0] })
            return checkDigit(norm) == cd ? [norm] : []
        }
        var results: [String] = []
        func dfs(_ i: Int, _ acc: [Character]) {
            if i == field.count {
                if checkDigit(String(acc)) == cd { results.append(String(acc)) }
                return
            }
            for c in perPos[i] { dfs(i + 1, acc + [c]) }
        }
        dfs(0, [])
        return results
    }

    /// Первый подходящий вариант поля (для однозначных полей — дат).
    static func recover(field: [Character], cdChar: Character, digitsOnly: Bool, cap: Int = 50_000) -> String? {
        recoverAll(field: field, cdChar: cdChar, digitsOnly: digitsOnly, cap: cap).first
    }

    private static func fit(_ s: String, to n: Int) -> String {
        if s.count == n { return s }
        if s.count > n { return String(s.prefix(n)) }
        return s + String(repeating: "<", count: n - s.count)
    }

    /// Варианты полной строки для формата заданной длины `target` из кусков `row`.
    /// Промежутки между кусками — заполнители '<'; распределяем недостающие '<' по стыкам
    /// (композиции, с ограничением). Это восстанавливает длину точно, не угадывая по ширине.
    static func candidateLines(for row: [String], target: Int) -> [String] {
        let pieces = row.map(normalizeLine).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return [] }
        let content = pieces.reduce(0) { $0 + $1.count }
        if pieces.count == 1 { return [fit(pieces[0], to: target)] }
        let need = target - content
        if need < 0 { return [fit(pieces.joined(), to: target)] }
        let gaps = pieces.count - 1
        var out: [String] = []
        for comp in compositions(total: need, parts: gaps, cap: 400) {
            var s = pieces[0]
            for g in 0..<gaps { s += String(repeating: "<", count: comp[g]) + pieces[g + 1] }
            out.append(fit(s, to: target))
        }
        return out.isEmpty ? [fit(pieces.joined(), to: target)] : out
    }

    /// Композиции числа `total` на `parts` неотрицательных слагаемых (с ограничением числа).
    private static func compositions(total: Int, parts: Int, cap: Int) -> [[Int]] {
        guard parts > 0 else { return [] }
        if parts == 1 { return [[total]] }
        var result: [[Int]] = []
        func go(_ remaining: Int, _ left: Int, _ acc: [Int]) {
            if result.count >= cap { return }
            if left == 1 { result.append(acc + [remaining]); return }
            for v in 0...remaining {
                if result.count >= cap { return }
                go(remaining - v, left - 1, acc + [v])
            }
        }
        go(total, parts, [])
        return result
    }

    /// Разбор из набора строк-кандидатов OCR с коррекцией ошибок. Пробует ВСЕ форматы
    /// (TD3 2×44, TD2 2×36, TD1 3×30) и принимает только тот, где сошлись ВСЕ контрольные.
    /// Если подходят несколько — предпочитает `prefer` (ожидаемый по типу документа).
    /// Заполняет поля ТОЛЬКО при `checkDigitsValid`.
    public static func parseRecovering(lines rawLines: [String],
                                       prefer: MRZResult.Format? = nil)
        -> (result: MRZResult?, diagnostics: MRZDiagnostics) {
        parseRecovering(rows: rawLines.map { [$0] }, prefer: prefer)
    }

    /// Вариант, принимающий КУСКИ каждой строки (из геометрической склейки). Для каждого
    /// формата достраивает длину по `candidateLines`.
    public static func parseRecovering(rows: [[String]],
                                       prefer: MRZResult.Format? = nil)
        -> (result: MRZResult?, diagnostics: MRZDiagnostics) {
        func normLen(_ row: [String]) -> Int { row.map(normalizeLine).reduce(0) { $0 + $1.count } }
        // Для подсчёта кандидатов в диагностике — те ряды, что похожи на MRZ по суммарной длине.
        let mrzRows = rows.filter { let n = normLen($0); return n >= 28 && n <= 46 }
        var diag = MRZDiagnostics(candidateLineCount: mrzRows.count)
        var valid: [MRZResult.Format: MRZResult] = [:]

        // Полные строки-кандидаты для формата длины target. Ряд имён/документа может быть
        // короче (OCR отбрасывает хвостовые '<'), поэтому берём всё, что не длиннее target+2.
        // Строки с сильным признаком (TD3 начинается с 'P') ставим первыми, чтобы правильно
        // выбрать строку имён при склейке.
        func lines(target: Int, strongPrefix: Character?) -> [String] {
            var out: [String] = []
            for row in rows {
                let n = normLen(row)
                guard n >= 8, n <= target + 2 else { continue }
                out += candidateLines(for: row, target: target)
            }
            if let p = strongPrefix {
                out.sort { ($0.first == p ? 0 : 1) < ($1.first == p ? 0 : 1) }
            }
            return Array(out.prefix(10))
        }

        // TD3 — две строки по 44.
        let td3 = lines(target: 44, strongPrefix: "P")
        if !td3.isEmpty {
            var fail: [String] = []
            outer3: for i in td3.indices {
                for j in td3.indices where j != i {
                    let (res, fails) = recoverTD3(td3[i], td3[j])
                    if let res, res.checkDigitsValid { valid[.td3] = res; break outer3 }
                    if fail.isEmpty { fail = fails }
                }
            }
            diag.attempts.append("td3 len=\(td3.map(\.count))" + (valid[.td3] != nil ? " ok" : " fail:\(fail.joined(separator: ","))"))
            if valid[.td3] == nil { diag.failedChecks = fail }
        }

        // TD2 — две строки по 36.
        let td2 = lines(target: 36, strongPrefix: nil)
        if !td2.isEmpty {
            var fail: [String] = []
            outer2: for i in td2.indices {
                for j in td2.indices where j != i {
                    let (res, fails) = recoverTD2(td2[i], td2[j])
                    if let res, res.checkDigitsValid { valid[.td2] = res; break outer2 }
                    if fail.isEmpty { fail = fails }
                }
            }
            diag.attempts.append("td2 len=\(td2.map(\.count))" + (valid[.td2] != nil ? " ok" : " fail:\(fail.joined(separator: ","))"))
        }

        // TD1 — три строки по 30.
        let td1 = lines(target: 30, strongPrefix: nil)
        if td1.count >= 3 {
            var fail: [String] = []
            outer1: for perm in orderedTriples(td1) {
                let (res, fails) = recoverTD1(perm.0, perm.1, perm.2)
                if let res, res.checkDigitsValid { valid[.td1] = res; break outer1 }
                if fail.isEmpty { fail = fails }
            }
            diag.attempts.append("td1 len=\(td1.map(\.count))" + (valid[.td1] != nil ? " ok" : " fail:\(fail.joined(separator: ","))"))
        }

        guard !valid.isEmpty else { return (nil, diag) }
        // Выбор: предпочтительный формат, иначе по приоритету TD3 → TD2 → TD1.
        let order: [MRZResult.Format] = {
            if let prefer, valid[prefer] != nil { return [prefer] }
            return [.td3, .td2, .td1]
        }()
        for fmt in order where valid[fmt] != nil {
            diag.detectedFormat = fmt.rawValue
            diag.recovered = true
            diag.failedChecks = []
            return (valid[fmt], diag)
        }
        return (nil, diag)
    }

    private static func orderedTriples(_ a: [String]) -> [(String, String, String)] {
        // Ограничиваем до первых 4 кандидатов, чтобы не раздувать перебор.
        let s = Array(a.prefix(4))
        var out: [(String, String, String)] = []
        for i in s.indices { for j in s.indices where j != i { for k in s.indices where k != i && k != j {
            out.append((s[i], s[j], s[k]))
        }}}
        return out
    }

    static func recoverTD3(_ l1: String, _ l2: String) -> (MRZResult?, [String]) {
        guard l1.count == 44, l2.count == 44 else { return (nil, ["формат"]) }
        let a = Array(l1), b = Array(l2)
        let issuingState = String(a[2..<5]).trimmingMRZ()
        let (surname, given) = names(String(a[5..<44]))
        let nationality = String(b[10..<13]).trimmingMRZ()
        let sex = normalizeSex(String(b[20..<21]))

        guard let birth = recover(field: Array(b[13..<19]), cdChar: b[19], digitsOnly: true),
              let birthDate = date(birth, isExpiry: false) else {
            return (nil, ["дата рождения"])
        }
        guard let expiry = recover(field: Array(b[21..<27]), cdChar: b[27], digitsOnly: true),
              let expiryDate = date(expiry, isExpiry: true) else {
            return (nil, ["срок"])
        }
        let docCandidates = recoverAll(field: Array(b[0..<9]), cdChar: b[9], digitsOnly: false)
        if docCandidates.isEmpty { return (nil, ["номер"]) }
        let optField = Array(b[28..<42])
        let optCandidates0 = recoverAll(field: optField, cdChar: b[42], digitsOnly: false)
        let optCandidates = optCandidates0.isEmpty ? [String(optField)] : optCandidates0

        // Номер и доп.поле неоднозначны — выбираем пару, при которой сходится СОСТАВНАЯ КЦ.
        // Это отсекает «валидный по полю, но неверный» номер.
        for docField in docCandidates {
            for optional in optCandidates {
                let composite = docField + String(checkDigit(docField))
                    + birth + String(checkDigit(birth))
                    + expiry + String(checkDigit(expiry))
                    + optional + String(checkDigit(optional))
                if cdValue(b[43]) == checkDigit(composite) {
                    let res = MRZResult(format: .td3, documentNumber: docField.trimmingMRZ(), surname: surname,
                                        givenNames: given, nationality: nationality, issuingState: issuingState,
                                        sex: sex, birthDate: birthDate, expiryDate: expiryDate, checkDigitsValid: true)
                    return (res, [])
                }
            }
        }
        return (nil, ["составная"])
    }

    /// TD2 (2×36): виза/карта. Строка 2: номер(9)+КЦ, гражд.(3), дата рожд.(6)+КЦ, пол,
    /// срок(6)+КЦ, доп.(7), составная КЦ. У доп.поля своей КЦ нет — оно входит в составную.
    static func recoverTD2(_ l1: String, _ l2: String) -> (MRZResult?, [String]) {
        guard l1.count == 36, l2.count == 36 else { return (nil, ["формат"]) }
        let a = Array(l1), b = Array(l2)
        let issuingState = String(a[2..<5]).trimmingMRZ()
        let (surname, given) = names(String(a[5..<36]))
        let nationality = String(b[10..<13]).trimmingMRZ()
        let sex = normalizeSex(String(b[20..<21]))

        guard let birth = recover(field: Array(b[13..<19]), cdChar: b[19], digitsOnly: true),
              let birthDate = date(birth, isExpiry: false) else {
            return (nil, ["дата рождения"])
        }
        guard let expiry = recover(field: Array(b[21..<27]), cdChar: b[27], digitsOnly: true),
              let expiryDate = date(expiry, isExpiry: true) else {
            return (nil, ["срок"])
        }
        let docCandidates = recoverAll(field: Array(b[0..<9]), cdChar: b[9], digitsOnly: false)
        if docCandidates.isEmpty { return (nil, ["номер"]) }
        let optional = String(b[28..<35])
        for docField in docCandidates {
            let composite = docField + String(checkDigit(docField))
                + birth + String(checkDigit(birth))
                + expiry + String(checkDigit(expiry)) + optional
            if cdValue(b[35]) == checkDigit(composite) {
                let res = MRZResult(format: .td2, documentNumber: docField.trimmingMRZ(), surname: surname,
                                    givenNames: given, nationality: nationality, issuingState: issuingState,
                                    sex: sex, birthDate: birthDate, expiryDate: expiryDate, checkDigitsValid: true)
                return (res, [])
            }
        }
        return (nil, ["составная"])
    }

    static func recoverTD1(_ l1: String, _ l2: String, _ l3: String) -> (MRZResult?, [String]) {
        guard l1.count == 30, l2.count == 30, l3.count == 30 else { return (nil, ["формат"]) }
        let a = Array(l1), b = Array(l2), c = Array(l3)
        let issuingState = String(a[2..<5]).trimmingMRZ()
        let (surname, given) = names(String(c[0..<30]))
        let nationality = String(b[15..<18]).trimmingMRZ()
        let sex = normalizeSex(String(b[7..<8]))

        guard let birth = recover(field: Array(b[0..<6]), cdChar: b[6], digitsOnly: true),
              let birthDate = date(birth, isExpiry: false) else {
            return (nil, ["дата рождения"])
        }
        guard let expiry = recover(field: Array(b[8..<14]), cdChar: b[14], digitsOnly: true),
              let expiryDate = date(expiry, isExpiry: true) else {
            return (nil, ["срок"])
        }
        let docCandidates = recoverAll(field: Array(a[5..<14]), cdChar: a[14], digitsOnly: false)
        if docCandidates.isEmpty { return (nil, ["номер"]) }
        let optional1 = String(a[15..<30])
        let optional2 = String(b[18..<29])
        // Составная (КЦ на позиции b[29]): номер+КЦ + optional1 + дата рожд.+КЦ + срок+КЦ + optional2.
        for docField in docCandidates {
            let composite = docField + String(checkDigit(docField)) + optional1
                + birth + String(checkDigit(birth)) + expiry + String(checkDigit(expiry)) + optional2
            if cdValue(b[29]) == checkDigit(composite) {
                let res = MRZResult(format: .td1, documentNumber: docField.trimmingMRZ(), surname: surname,
                                    givenNames: given, nationality: nationality, issuingState: issuingState,
                                    sex: sex, birthDate: birthDate, expiryDate: expiryDate, checkDigitsValid: true)
                return (res, [])
            }
        }
        return (nil, ["составная"])
    }
}

private extension ArraySlice where Element == String {
    func nilIfNotCount(_ n: Int) -> [String]? { count == n ? Array(self) : nil }
}

private extension String {
    func trimmingMRZ() -> String { replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespaces) }
}
