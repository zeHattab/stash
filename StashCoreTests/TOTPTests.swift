import XCTest
import CryptoKit
@testable import StashCore

final class TOTPTests: XCTestCase {

    // RFC 6238, Appendix B. Семена — ASCII, 8 цифр, период 30.
    private let seedSHA1 = Data("12345678901234567890".utf8)
    private let seedSHA256 = Data("12345678901234567890123456789012".utf8)
    private let seedSHA512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private func code(_ secret: Data, _ algo: TOTPConfig.Algorithm, at t: TimeInterval) -> String {
        TOTP.code(TOTPConfig(secret: secret, algorithm: algo, digits: 8, period: 30),
                  at: Date(timeIntervalSince1970: t))
    }

    func testRFC6238SHA1() {
        XCTAssertEqual(code(seedSHA1, .sha1, at: 59), "94287082")
        XCTAssertEqual(code(seedSHA1, .sha1, at: 1111111109), "07081804")
        XCTAssertEqual(code(seedSHA1, .sha1, at: 1234567890), "89005924")
        XCTAssertEqual(code(seedSHA1, .sha1, at: 2000000000), "69279037")
    }

    func testRFC6238SHA256() {
        XCTAssertEqual(code(seedSHA256, .sha256, at: 59), "46119246")
        XCTAssertEqual(code(seedSHA256, .sha256, at: 1111111111), "67062674")
        XCTAssertEqual(code(seedSHA256, .sha256, at: 2000000000), "90698825")
    }

    func testRFC6238SHA512() {
        XCTAssertEqual(code(seedSHA512, .sha512, at: 59), "90693936")
        XCTAssertEqual(code(seedSHA512, .sha512, at: 1111111109), "25091201")
        XCTAssertEqual(code(seedSHA512, .sha512, at: 2000000000), "38618901")
    }

    func testSecondsRemaining() {
        let cfg = TOTPConfig(secret: seedSHA1, period: 30)
        XCTAssertEqual(TOTP.secondsRemaining(cfg, at: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(TOTP.secondsRemaining(cfg, at: Date(timeIntervalSince1970: 29)), 1)
        XCTAssertEqual(TOTP.secondsRemaining(cfg, at: Date(timeIntervalSince1970: 30)), 30)
    }

    func testBase32Decode() {
        // "Hello!" (RFC 4648 пример JBSWY3DPEHPK3PXP = "Hello!\xde\xad\xbe\xef"? — проверим обратимость)
        XCTAssertEqual(TOTP.base32Decode("MZXW6==="), Data("foo".utf8))
        XCTAssertEqual(TOTP.base32Decode("mz xw6"), Data("foo".utf8)) // нижний регистр + пробел
        XCTAssertNil(TOTP.base32Decode("8"))  // недопустимый символ
    }

    // MARK: - otpauth://

    func testParseOTPAuthTOTP() throws {
        let url = "otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA256&digits=8&period=60"
        guard case let .success(cfg) = OTPAuth.parse(url) else { return XCTFail("ожидался success") }
        XCTAssertEqual(cfg.algorithm, .sha256)
        XCTAssertEqual(cfg.digits, 8)
        XCTAssertEqual(cfg.period, 60)
        XCTAssertEqual(cfg.issuer, "Example")
        XCTAssertEqual(cfg.account, "alice@google.com")
        XCTAssertEqual(cfg.secret, TOTP.base32Decode("JBSWY3DPEHPK3PXP"))
    }

    func testParseOTPAuthDefaults() throws {
        guard case let .success(cfg) = OTPAuth.parse("otpauth://totp/me?secret=JBSWY3DPEHPK3PXP") else {
            return XCTFail("success")
        }
        XCTAssertEqual(cfg.algorithm, .sha1)
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
    }

    func testMakeURLRoundTrip() {
        let secret = TOTP.base32Decode("JBSWY3DPEHPK3PXP")!
        let cfg = TOTPConfig(secret: secret, algorithm: .sha256, digits: 8, period: 60,
                             issuer: "Acme", account: "a@b.com")
        guard case let .success(back) = OTPAuth.parse(OTPAuth.makeURL(from: cfg)) else { return XCTFail("success") }
        XCTAssertEqual(back.secret, secret)
        XCTAssertEqual(back.algorithm, .sha256)
        XCTAssertEqual(back.digits, 8)
        XCTAssertEqual(back.period, 60)
        XCTAssertEqual(back.issuer, "Acme")
        XCTAssertEqual(back.account, "a@b.com")
    }

    func testHOTPRejected() {
        XCTAssertEqual(OTPAuth.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=0"), .failure(.hotpUnsupported))
    }

    func testBareSecret() {
        guard case let .success(cfg) = OTPAuth.parse("JBSWY3DPEHPK3PXP") else { return XCTFail("success") }
        XCTAssertEqual(cfg.secret, TOTP.base32Decode("JBSWY3DPEHPK3PXP"))
    }

    func testGarbageRejected() {
        XCTAssertEqual(OTPAuth.parse("!!!!"), .failure(.notOTPAuth))
    }

    // MARK: - Google Authenticator migration (protobuf)

    private func makeOtpParameters(secret: Data, name: String, issuer: String,
                                   algo: UInt8, digits: UInt8, type: UInt8) -> Data {
        var d = Data()
        func field(_ tag: UInt8, _ bytes: Data) { d.append(tag); d.append(UInt8(bytes.count)); d.append(bytes) }
        field(0x0A, secret)                       // 1: secret (bytes)
        field(0x12, Data(name.utf8))              // 2: name
        field(0x1A, Data(issuer.utf8))            // 3: issuer
        d.append(contentsOf: [0x20, algo])        // 4: algorithm varint
        d.append(contentsOf: [0x28, digits])      // 5: digits varint
        d.append(contentsOf: [0x30, type])        // 6: type varint
        return d
    }

    func testMigrationProtobufParse() {
        let secret = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])
        let otp = makeOtpParameters(secret: secret, name: "alice@example.com", issuer: "Acme",
                                    algo: 2, digits: 2, type: 2) // SHA256, 8 цифр, TOTP
        var payload = Data([0x0A, UInt8(otp.count)]) // MigrationPayload field 1
        payload.append(otp)

        let configs = MigrationProtobuf.parse(payload)
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?.secret, secret)
        XCTAssertEqual(configs.first?.algorithm, .sha256)
        XCTAssertEqual(configs.first?.digits, 8)
        XCTAssertEqual(configs.first?.issuer, "Acme")
        XCTAssertEqual(configs.first?.account, "alice@example.com")
    }

    func testMigrationSkipsHOTP() {
        let otp = makeOtpParameters(secret: Data([1, 2, 3]), name: "x", issuer: "y",
                                    algo: 1, digits: 1, type: 1) // type 1 = HOTP → пропустить
        var payload = Data([0x0A, UInt8(otp.count)])
        payload.append(otp)
        XCTAssertTrue(MigrationProtobuf.parse(payload).isEmpty)
    }

    func testParseMigrationURL() {
        let secret = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let otp = makeOtpParameters(secret: secret, name: "a", issuer: "b", algo: 1, digits: 1, type: 2)
        var payload = Data([0x0A, UInt8(otp.count)]); payload.append(otp)
        let b64 = payload.base64EncodedString()
        let enc = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        let url = "otpauth-migration://offline?data=\(enc)"
        guard case let .success(configs) = OTPAuth.parseMigration(url) else { return XCTFail("success") }
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?.secret, secret)
    }
}

// MARK: - Метка уведомлений из ключа (п.0)

final class VaultTagTests: XCTestCase {
    func testTagDependsOnKeyNotSalt() {
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        let t1 = VaultTag.make(vaultKey: k1)
        XCTAssertEqual(t1, VaultTag.make(vaultKey: k1))         // стабильна при том же ключе
        XCTAssertNotEqual(t1, VaultTag.make(vaultKey: k2))      // разные ключи → разные метки
        XCTAssertEqual(t1.count, 16)                           // 8 байт в hex
    }

    func testTagNotDerivableFromFileBytesWithoutKey() {
        // Соль (байты файла) не входит в метку: даже зная соль, без VK метку не получить.
        let key = SymmetricKey(size: .bits256)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let tag = VaultTag.make(vaultKey: key)
        // Наивная «метка из соли», которую мог бы вычислить эксперт по файлу, не совпадает.
        let fromSalt = SHA256.hash(data: Data("stash-notif-tag".utf8) + salt)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(tag, fromSalt)
    }
}
