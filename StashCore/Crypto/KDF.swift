import Foundation
import CryptoKit
import CommonCrypto

/// Алгоритм вывода ключа. Хранится в заголовке, чтобы позже можно было
/// сменить KDF (например, на Argon2) без потери данных.
enum KDFAlgorithm: String, Codable, Sendable, Equatable {
    case pbkdf2HMACSHA256 = "pbkdf2-hmac-sha256"
}

/// Параметры KDF, сохраняемые в заголовке хранилища.
struct KDFParameters: Codable, Sendable, Equatable {
    var algorithm: KDFAlgorithm
    var iterations: UInt32
    var salt: Data

    /// Параметры по умолчанию: PBKDF2-HMAC-SHA256, случайная соль 16 байт.
    /// Итерации по умолчанию 600 000; в тестах задаются меньше для скорости.
    static func makeDefault(iterations: UInt32 = 600_000) throws -> KDFParameters {
        KDFParameters(algorithm: .pbkdf2HMACSHA256,
                      iterations: iterations,
                      salt: try Random.bytes(16))
    }
}

enum KDF {
    /// Выводит ключ из пароля по заданным параметрам.
    /// Пароль передаётся как `Data` и не копируется в строки.
    static func derive(password: Data, parameters: KDFParameters, keyLength: Int = 32) throws -> SymmetricKey {
        switch parameters.algorithm {
        case .pbkdf2HMACSHA256:
            var derived = [UInt8](repeating: 0, count: keyLength)
            let status: Int32 = password.withUnsafeBytes { pw in
                parameters.salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        salt.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        parameters.salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        parameters.iterations,
                        &derived,
                        keyLength
                    )
                }
            }
            guard status == Int32(kCCSuccess) else {
                throw VaultError.ioError("PBKDF2 failed: \(status)")
            }
            let key = SymmetricKey(data: Data(derived))
            // Обнуляем промежуточный буфер с ключевым материалом.
            for i in derived.indices { derived[i] = 0 }
            return key
        }
    }
}
