import Foundation
import CryptoKit

/// Непрозрачная метка сейфа для привязки локальных уведомлений, выводимая ИЗ КЛЮЧА сейфа
/// (не из соли!). Соль лежит в файле открыто — по метке на её основе при экспертизе можно
/// было бы сопоставить слоты и доказать наличие второго сейфа. Ключ (VK) вне слота не
/// существует, поэтому HMAC-SHA256(VK, "stash-notif-v1") метку из файла восстановить нельзя.
public enum VaultTag {
    public static func make(vaultKey: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("stash-notif-v1".utf8), using: vaultKey)
        return mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
