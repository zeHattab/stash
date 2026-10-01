import Foundation
import CryptoKit

/// Примитивы шифрования поверх CryptoKit (AES-256-GCM).
///
/// Разделение ошибок намеренное:
/// - неудачная разворачивание VK (неверный KEK) → `wrongPassword`;
/// - неудачная расшифровка данных (подмена/порча) → `corrupted`.
enum Crypto {

    /// Оборачивает (шифрует) Vault Key ключом KEK. Результат: nonce‖ciphertext‖tag.
    static func wrap(key vaultKey: SymmetricKey, with kek: SymmetricKey) throws -> Data {
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(keyData, using: kek)
        guard let combined = sealed.combined else {
            throw VaultError.ioError("GCM combined box unavailable")
        }
        return combined
    }

    /// Разворачивает Vault Key ключом KEK. Неверный KEK → `wrongPassword`.
    static func unwrap(_ wrapped: Data, with kek: SymmetricKey) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let keyData = try AES.GCM.open(box, using: kek)
            return SymmetricKey(data: keyData)
        } catch {
            throw VaultError.wrongPassword
        }
    }

    /// Шифрует данные ключом VK, аутентифицируя заголовок (AAD).
    /// Nonce генерируется случайно на каждый вызов.
    static func encrypt(_ plaintext: Data, using vaultKey: SymmetricKey, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: vaultKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw VaultError.ioError("GCM combined box unavailable")
        }
        return combined
    }

    /// Расшифровывает данные ключом VK с проверкой AAD. Провал проверки → `corrupted`.
    static func decrypt(_ combined: Data, using vaultKey: SymmetricKey, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: vaultKey, authenticating: aad)
        } catch {
            throw VaultError.corrupted
        }
    }
}
