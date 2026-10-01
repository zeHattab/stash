import Foundation

/// Ключ восстановления: 160 бит из SecRandomCopyBytes, алфавит без похожих
/// символов (нет 0/O/1/I/L). Показывается 8 группами по 4 символа.
public enum RecoveryKey {
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let groupCount = 8
    static let groupLength = 4

    private static let allowed = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Новый ключ в виде "ABCD-EFGH-…" (8 групп по 4).
    public static func generate() throws -> String {
        var chars: [Character] = []
        for _ in 0..<(groupCount * groupLength) {
            chars.append(alphabet[try PasswordGenerator.randomIndex(alphabet.count)])
        }
        return stride(from: 0, to: chars.count, by: groupLength)
            .map { String(chars[$0 ..< min($0 + groupLength, chars.count)]) }
            .joined(separator: "-")
    }

    /// Канонизация ввода: верхний регистр, только символы алфавита (пробелы, дефисы
    /// и прочее отбрасываются), регистронезависимо.
    public static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { allowed.contains($0) })
    }

    /// Разбивает канонический ключ на группы для показа.
    public static func grouped(_ input: String) -> String {
        let canon = Array(normalize(input))
        return stride(from: 0, to: canon.count, by: groupLength)
            .map { String(canon[$0 ..< min($0 + groupLength, canon.count)]) }
            .joined(separator: "-")
    }

    /// Байты для KDF (из канонической формы).
    static func keyData(_ input: String) -> Data {
        Data(normalize(input).utf8)
    }
}
