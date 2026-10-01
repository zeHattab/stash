import Foundation
import Security

/// Криптографически стойкий генератор случайных байтов (SecRandomCopyBytes).
enum Random {
    static func bytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw VaultError.ioError("SecRandomCopyBytes failed: \(status)")
        }
        return data
    }
}
