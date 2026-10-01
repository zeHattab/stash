import Foundation

/// Качественная оценка надёжности пароля.
public enum PasswordStrength: Int, Sendable, Equatable, Comparable, CaseIterable {
    case veryWeak = 0
    case weak = 1
    case fair = 2
    case strong = 3
    case veryStrong = 4

    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Результат оценки. Нужен и UI (индикатор), и тестам.
public struct PasswordAssessment: Sendable, Equatable {
    public var strength: PasswordStrength
    public var length: Int
    public var isCommon: Bool
    public var meetsMinimumLength: Bool
}

public enum PasswordEvaluator {

    public static let minimumLength = 10

    /// Короткий встроенный список распространённых паролей (~100), без сети.
    /// Сравнение регистронезависимое.
    static let commonPasswords: Set<String> = [
        "123456", "password", "123456789", "12345678", "12345", "qwerty", "1234567",
        "111111", "1234567890", "123123", "abc123", "1234", "password1", "iloveyou",
        "000000", "qwerty123", "zaq12wsx", "dragon", "sunshine", "princess", "letmein",
        "654321", "monkey", "27653", "1qaz2wsx", "123321", "qwertyuiop", "superman",
        "asdfghjkl", "football", "welcome", "admin", "passw0rd", "master", "michael",
        "696969", "666666", "shadow", "123456a", "qwe123", "121212", "aa123456",
        "flower", "555555", "loveme", "7777777", "888888", "jordan", "hunter",
        "trustno1", "ranger", "buster", "thomas", "tigger", "robert", "soccer",
        "batman", "test", "pass", "killer", "hockey", "george", "charlie", "andrew",
        "michelle", "love", "jessica", "asdf", "pepper", "daniel", "access", "123",
        "whatever", "qazwsx", "trinity", "zxcvbnm", "login", "starwars", "cheese",
        "freedom", "ginger", "baseball", "summer", "hello", "amanda", "nicole",
        "chocolate", "computer", "jennifer", "secret", "internet", "service",
        "canada", "hello123", "ashley", "root", "toor", "pokemon", "money", "qwerty1",
        "password123", "google", "mustang", "harley",
    ]

    public static func assess(_ password: String) -> PasswordAssessment {
        let length = password.count
        let meetsMinimum = length >= minimumLength
        let isCommon = commonPasswords.contains(password.lowercased())

        if isCommon {
            return PasswordAssessment(strength: .veryWeak, length: length,
                                      isCommon: true, meetsMinimumLength: meetsMinimum)
        }
        if length == 0 {
            return PasswordAssessment(strength: .veryWeak, length: 0,
                                      isCommon: false, meetsMinimumLength: false)
        }

        let hasLower = password.contains { $0.isLowercase }
        let hasUpper = password.contains { $0.isUppercase }
        let hasDigit = password.contains { $0.isNumber }
        let hasSymbol = password.contains { !$0.isLetter && !$0.isNumber }
        let classes = [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count

        var score = 0
        score += min(length, 24)             // до 24 за длину
        score += (classes - 1) * 6           // 0…18 за разнообразие классов
        if length >= 12 { score += 4 }
        if length >= 16 { score += 6 }

        // штраф за малое число уникальных символов (повторы/монотонность)
        let uniqueRatio = Double(Set(password).count) / Double(length)
        if uniqueRatio < 0.4 { score -= 15 }
        else if uniqueRatio < 0.6 { score -= 6 }

        let strength: PasswordStrength
        if length < minimumLength {
            // Короткие пароли не могут быть выше «слабого».
            strength = (score <= 10) ? .veryWeak : .weak
        } else if score < 22 {
            strength = .weak
        } else if score < 30 {
            strength = .fair
        } else if score < 40 {
            strength = .strong
        } else {
            strength = .veryStrong
        }

        return PasswordAssessment(strength: strength, length: length,
                                  isCommon: false, meetsMinimumLength: meetsMinimum)
    }
}
