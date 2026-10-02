import Foundation

public enum OTPError: Error, Equatable, Sendable {
    case notOTPAuth
    case hotpUnsupported
    case invalidSecret
    case unsupportedScheme
}

/// Разбор otpauth://totp/… и импорт из Google Authenticator (otpauth-migration://).
public enum OTPAuth {

    /// Разбирает одиночную ссылку otpauth://totp/… или «голый» Base32-секрет.
    public static func parse(_ raw: String) -> Result<TOTPConfig, OTPError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("otpauth://") else {
            // «Голый» секрет: Base32 с параметрами по умолчанию.
            if let secret = TOTP.base32Decode(s), !secret.isEmpty {
                return .success(TOTPConfig(secret: secret))
            }
            return .failure(.notOTPAuth)
        }
        guard let comps = URLComponents(string: s), let host = comps.host?.lowercased() else {
            return .failure(.unsupportedScheme)
        }
        if host == "hotp" { return .failure(.hotpUnsupported) }
        guard host == "totp" else { return .failure(.unsupportedScheme) }

        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }

        guard let secretStr = q("secret"), let secret = TOTP.base32Decode(secretStr), !secret.isEmpty else {
            return .failure(.invalidSecret)
        }
        let algorithm = TOTPConfig.Algorithm(rawValue: (q("algorithm") ?? "SHA1").uppercased()) ?? .sha1
        let digits = Int(q("digits") ?? "") ?? 6
        let period = Int(q("period") ?? "") ?? 30

        // Метка: /Issuer:Account ; issuer из query имеет приоритет.
        let label = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
        var issuer = q("issuer")
        var account = label.removingPercentEncoding ?? label
        if let colon = account.firstIndex(of: ":") {
            let left = String(account[account.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let right = String(account[account.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if issuer == nil || issuer?.isEmpty == true { issuer = left }
            account = right
        }
        return .success(TOTPConfig(
            secret: secret,
            algorithm: algorithm,
            digits: [6, 8].contains(digits) ? digits : 6,
            period: period > 0 ? period : 30,
            issuer: issuer?.isEmpty == true ? nil : issuer,
            account: account.isEmpty ? nil : account))
    }

    /// Конфиг из строки, сохранённой в записи (otpauth-URL или «голый» секрет); nil если не TOTP.
    public static func config(fromStored stored: String) -> TOTPConfig? {
        if case let .success(cfg) = parse(stored) { return cfg }
        return nil
    }

    // MARK: - Импорт из Google Authenticator (otpauth-migration://offline?data=…)

    /// Разбирает экспорт Google Authenticator. Возвращает только TOTP-записи.
    public static func parseMigration(_ raw: String) -> Result<[TOTPConfig], OTPError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("otpauth-migration://") else { return .failure(.unsupportedScheme) }
        guard let comps = URLComponents(string: s),
              let dataParam = (comps.queryItems ?? []).first(where: { $0.name == "data" })?.value else {
            return .failure(.invalidSecret)
        }
        // queryItems уже снимает percent-encoding; восстановим Base64 (+/ и =).
        let b64 = dataParam.replacingOccurrences(of: " ", with: "+")
        guard let payload = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
            return .failure(.invalidSecret)
        }
        let configs = MigrationProtobuf.parse(payload)
        return .success(configs)
    }
}

/// Минимальный разбор protobuf MigrationPayload Google Authenticator — без зависимостей.
/// MigrationPayload { repeated OtpParameters otp_parameters = 1; }
/// OtpParameters { bytes secret=1; string name=2; string issuer=3; Algorithm algorithm=4;
///                 DigitCount digits=5; OtpType type=6; }
enum MigrationProtobuf {

    static func parse(_ data: Data) -> [TOTPConfig] {
        var out: [TOTPConfig] = []
        var r = Reader(data)
        while let field = r.readTag() {
            if field.number == 1, field.wire == 2, let sub = r.readLengthDelimited() {
                if let cfg = parseOtpParameters(sub) { out.append(cfg) }
            } else {
                r.skip(field.wire)
            }
        }
        return out
    }

    private static func parseOtpParameters(_ data: Data) -> TOTPConfig? {
        var secret: Data?
        var name: String?
        var issuer: String?
        var algo: TOTPConfig.Algorithm = .sha1
        var digits = 6
        var type = 0
        var r = Reader(data)
        while let field = r.readTag() {
            switch (field.number, field.wire) {
            case (1, 2): secret = r.readLengthDelimited()
            case (2, 2): name = r.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) }
            case (3, 2): issuer = r.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) }
            case (4, 0): algo = [1: .sha1, 2: .sha256, 3: .sha512][Int(r.readVarint() ?? 1)] ?? .sha1
            case (5, 0): digits = (r.readVarint() ?? 1) == 2 ? 8 : 6
            case (6, 0): type = Int(r.readVarint() ?? 0)
            default: r.skip(field.wire)
            }
        }
        guard type == 2, let secret, !secret.isEmpty else { return nil } // только TOTP
        return TOTPConfig(secret: secret, algorithm: algo, digits: digits, period: 30,
                          issuer: issuer?.isEmpty == true ? nil : issuer,
                          account: name?.isEmpty == true ? nil : name)
    }

    /// Простой курсор по байтам protobuf.
    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        mutating func readTag() -> (number: Int, wire: Int)? {
            guard i < bytes.count, let key = readVarint() else { return nil }
            return (Int(key >> 3), Int(key & 0x7))
        }

        mutating func readLengthDelimited() -> Data? {
            guard let len = readVarint(), i + Int(len) <= bytes.count else { return nil }
            let slice = bytes[i..<(i + Int(len))]
            i += Int(len)
            return Data(slice)
        }

        mutating func skip(_ wire: Int) {
            switch wire {
            case 0: _ = readVarint()
            case 1: i += 8
            case 2: _ = readLengthDelimited()
            case 5: i += 4
            default: i = bytes.count
            }
        }
    }
}
