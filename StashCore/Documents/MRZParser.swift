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

    public enum Format: String, Sendable, Equatable { case td1, td3 }
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
}

private extension ArraySlice where Element == String {
    func nilIfNotCount(_ n: Int) -> [String]? { count == n ? Array(self) : nil }
}

private extension String {
    func trimmingMRZ() -> String { replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespaces) }
}
