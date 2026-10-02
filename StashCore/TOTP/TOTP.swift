import Foundation
import CryptoKit

/// Параметры одноразового кода (TOTP).
public struct TOTPConfig: Sendable, Equatable {
    public enum Algorithm: String, Sendable, Equatable, CaseIterable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }
    public var secret: Data          // СЫРЫЕ байты секрета (не Base32)
    public var algorithm: Algorithm
    public var digits: Int           // 6 или 8
    public var period: Int           // 30 или 60
    public var issuer: String?
    public var account: String?

    public init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6,
                period: Int = 30, issuer: String? = nil, account: String? = nil) {
        self.secret = secret; self.algorithm = algorithm; self.digits = digits
        self.period = period; self.issuer = issuer; self.account = account
    }
}

/// Генерация кодов по RFC 4226 (HOTP) и RFC 6238 (TOTP). Без сети, на устройстве.
public enum TOTP {

    /// Декодер Base32 (RFC 4648) с допуском пробелов, дефисов, нижнего регистра и '='.
    public static func base32Decode(_ string: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map = [Character: Int]()
        for (i, c) in alphabet.enumerated() { map[c] = i }
        let clean = string.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        guard !clean.isEmpty else { return nil }
        var bits = 0, value = 0
        var out = [UInt8]()
        for ch in clean {
            guard let v = map[ch] else { return nil }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return Data(out)
    }

    /// Кодер Base32 (RFC 4648, без паддинга).
    public static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var bits = 0, value = 0
        for b in data {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 0x1F]) }
        return out
    }

    private static func hmac(_ message: Data, key: SymmetricKey, algorithm: TOTPConfig.Algorithm) -> Data {
        switch algorithm {
        case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
    }

    /// HOTP (RFC 4226): код для счётчика.
    public static func hotp(secret: Data, counter: UInt64,
                            algorithm: TOTPConfig.Algorithm = .sha1, digits: Int = 6) -> String {
        var big = counter.bigEndian
        let counterData = withUnsafeBytes(of: &big) { Data($0) }
        let hash = hmac(counterData, key: SymmetricKey(data: secret), algorithm: algorithm)
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary = (UInt32(hash[offset]) & 0x7F) << 24
            | (UInt32(hash[offset + 1]) & 0xFF) << 16
            | (UInt32(hash[offset + 2]) & 0xFF) << 8
            | (UInt32(hash[offset + 3]) & 0xFF)
        let mod = UInt32(pow(10.0, Double(digits)))
        let code = binary % mod
        return String(format: "%0\(digits)u", code)
    }

    /// TOTP (RFC 6238): код на момент времени.
    public static func code(_ config: TOTPConfig, at date: Date = Date()) -> String {
        let counter = UInt64(floor(date.timeIntervalSince1970 / Double(config.period)))
        return hotp(secret: config.secret, counter: counter,
                    algorithm: config.algorithm, digits: config.digits)
    }

    /// Секунд до смены кода (1…period).
    public static func secondsRemaining(_ config: TOTPConfig, at date: Date = Date()) -> Int {
        let p = config.period
        let elapsed = Int(floor(date.timeIntervalSince1970)) % p
        return p - elapsed
    }
}
