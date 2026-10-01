import XCTest
import CryptoKit
@testable import StashCore

final class CryptoTests: XCTestCase {

    func testWrapUnwrapRoundTrip() throws {
        let kek = SymmetricKey(size: .bits256)
        let vk = SymmetricKey(size: .bits256)
        let wrapped = try Crypto.wrap(key: vk, with: kek)
        let unwrapped = try Crypto.unwrap(wrapped, with: kek)
        XCTAssertEqual(unwrapped, vk)
    }

    func testUnwrapWithWrongKEKThrowsWrongPassword() throws {
        let kek = SymmetricKey(size: .bits256)
        let wrong = SymmetricKey(size: .bits256)
        let vk = SymmetricKey(size: .bits256)
        let wrapped = try Crypto.wrap(key: vk, with: kek)
        XCTAssertThrowsError(try Crypto.unwrap(wrapped, with: wrong)) { error in
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
    }

    func testEncryptDecryptWithMatchingAAD() throws {
        let vk = SymmetricKey(size: .bits256)
        let aad = Data("header-bytes".utf8)
        let message = Data("top secret".utf8)
        let ct = try Crypto.encrypt(message, using: vk, aad: aad)
        let pt = try Crypto.decrypt(ct, using: vk, aad: aad)
        XCTAssertEqual(pt, message)
    }

    func testDecryptWithWrongAADThrowsCorrupted() throws {
        let vk = SymmetricKey(size: .bits256)
        let ct = try Crypto.encrypt(Data("top secret".utf8), using: vk, aad: Data("header-A".utf8))
        XCTAssertThrowsError(try Crypto.decrypt(ct, using: vk, aad: Data("header-B".utf8))) { error in
            XCTAssertEqual(error as? VaultError, .corrupted)
        }
    }

    func testTwoEncryptionsUseDifferentNonces() throws {
        let vk = SymmetricKey(size: .bits256)
        let aad = Data("h".utf8)
        let message = Data("same plaintext".utf8)
        let ct1 = try Crypto.encrypt(message, using: vk, aad: aad)
        let ct2 = try Crypto.encrypt(message, using: vk, aad: aad)
        XCTAssertNotEqual(ct1, ct2)
    }
}
