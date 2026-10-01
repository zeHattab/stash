import Foundation
import Security

public struct PasswordGeneratorOptions: Sendable, Equatable, Codable {
    public var length: Int
    public var useUppercase: Bool
    public var useLowercase: Bool
    public var useDigits: Bool
    public var useSymbols: Bool
    public var excludeSimilar: Bool

    public init(
        length: Int = 20,
        useUppercase: Bool = true,
        useLowercase: Bool = true,
        useDigits: Bool = true,
        useSymbols: Bool = true,
        excludeSimilar: Bool = false
    ) {
        self.length = length
        self.useUppercase = useUppercase
        self.useLowercase = useLowercase
        self.useDigits = useDigits
        self.useSymbols = useSymbols
        self.excludeSimilar = excludeSimilar
    }

    public static let `default` = PasswordGeneratorOptions()
}

public enum PasswordGeneratorError: Error, Equatable, Sendable {
    case noCharacterClass
}

public enum PasswordGenerator {

    public static let minLength = 8
    public static let maxLength = 64

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.?/")
    /// Похожие друг на друга символы, которые можно исключить.
    private static let similar: Set<Character> = ["0", "O", "o", "1", "l", "I"]

    /// Классы символов, включённые опциями (после исключения похожих).
    static func enabledClasses(_ options: PasswordGeneratorOptions) -> [[Character]] {
        var classes: [[Character]] = []
        if options.useLowercase { classes.append(lowercase) }
        if options.useUppercase { classes.append(uppercase) }
        if options.useDigits { classes.append(digits) }
        if options.useSymbols { classes.append(symbols) }
        if options.excludeSimilar {
            classes = classes.map { $0.filter { !similar.contains($0) } }
        }
        return classes.filter { !$0.isEmpty }
    }

    public static func generate(_ options: PasswordGeneratorOptions) throws -> String {
        let length = min(max(options.length, minLength), maxLength)
        let classes = enabledClasses(options)
        guard !classes.isEmpty else { throw PasswordGeneratorError.noCharacterClass }

        let pool = classes.flatMap { $0 }
        var chars: [Character] = []
        chars.reserveCapacity(length)

        // Гарантируем по одному символу каждого включённого класса (сколько влезает).
        for charClass in classes where chars.count < length {
            chars.append(charClass[try randomIndex(charClass.count)])
        }
        // Добираем остаток из общего пула.
        while chars.count < length {
            chars.append(pool[try randomIndex(pool.count)])
        }
        // Перемешиваем (Fisher–Yates на криптослучайности), чтобы гарантированные
        // символы не стояли в начале.
        try shuffle(&chars)
        return String(chars)
    }

    // MARK: - Криптослучайность

    private static func randomUInt32() throws -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw VaultError.ioError("SecRandomCopyBytes failed: \(status)")
        }
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    /// Равномерный индекс в [0, count) без смещения по модулю (rejection sampling).
    static func randomIndex(_ count: Int) throws -> Int {
        precondition(count > 0)
        let range = UInt32(count)
        let maxMultiple = (UInt32.max / range) * range
        while true {
            let r = try randomUInt32()
            if r < maxMultiple { return Int(r % range) }
        }
    }

    static func shuffle(_ array: inout [Character]) throws {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            let j = try randomIndex(i + 1)
            array.swapAt(i, j)
        }
    }
}
