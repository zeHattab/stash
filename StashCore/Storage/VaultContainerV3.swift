import Foundation

/// Контейнер v3. Исправляет утечку v2: в слоте НЕТ ни одного открытого поля,
/// по которому занятый слот отличался бы от случайного.
///
/// Внешний заголовок (общий, допускает магию/версию):
///   magic(5) version(1) algo(1) iterations(4,BE) slotSize(4,BE)  = 15 байт
/// Слот (ровно slotSize байт, всё выглядит как случайные данные):
///   salt(16) ‖ wrapMaster(60) ‖ wrapRecovery(60) ‖ payloadCiphertext(до конца слота)
/// Длина полезной нагрузки хранится ВНУТРИ шифртекста (len-префикс перед JSON,
/// затем случайный паддинг), поэтому шифртекст ровно заполняет слот и открытых
/// полей длины нет. wrapMaster/wrapRecovery — выводы AES-GCM (nonce/ct/tag),
/// неотличимые от случайных байтов. Неиспользуемый слот — сплошь случайные байты.
enum VaultContainerV3 {
    static let magic: [UInt8] = Array("STSH3".utf8)
    static let version: UInt8 = 3
    static let algoPBKDF2: UInt8 = 1

    static let outerHeaderSize = 15
    static let saltLen = 16
    static let wrapLen = 60                 // AES-GCM(32-байтовый VK) = 12+32+16
    static let headLen = 136                // salt + wrapMaster + wrapRecovery
    static let gcmOverhead = 28             // nonce(12) + tag(16)
    static let defaultSlotSize = 262_144    // 256 КБ, фиксирован (без роста)

    static func innerSize(slotSize: Int) -> Int { slotSize - headLen - gcmOverhead }

    static func isV3(_ data: Data) -> Bool {
        data.count >= magic.count && Array(data.prefix(magic.count)) == magic
    }

    static func immutableMeta(iterations: UInt32) -> Data {
        var b = magic
        b.append(version)
        b.append(algoPBKDF2)
        b += be32(iterations)
        return Data(b)
    }

    static func serialize(iterations: UInt32, slotSize: Int, slot0: Data, slot1: Data) -> Data {
        var b = magic
        b.append(version)
        b.append(algoPBKDF2)
        b += be32(iterations)
        b += be32(UInt32(slotSize))
        var data = Data(b)
        data.append(slot0)
        data.append(slot1)
        return data
    }

    struct Container {
        var iterations: UInt32
        var slotSize: Int
        var slots: [Data]
    }

    static func parse(_ data: Data) throws -> Container {
        let bytes = [UInt8](data)
        guard bytes.count >= outerHeaderSize, Array(bytes[0..<magic.count]) == magic else {
            throw VaultError.corrupted
        }
        let ver = bytes[5]
        guard ver == version else { throw VaultError.unsupportedVersion(Int(ver)) }
        let iterations = readBE32(bytes, 7)
        let slotSize = Int(readBE32(bytes, 11))
        guard slotSize > headLen + gcmOverhead,
              bytes.count >= outerHeaderSize + slotSize * 2 else { throw VaultError.corrupted }
        let s0 = Data(bytes[outerHeaderSize ..< outerHeaderSize + slotSize])
        let s1 = Data(bytes[outerHeaderSize + slotSize ..< outerHeaderSize + 2 * slotSize])
        return Container(iterations: iterations, slotSize: slotSize, slots: [s0, s1])
    }

    static func buildSlot(salt: Data, wrapMaster: Data, wrapRecovery: Data, payloadCiphertext: Data, slotSize: Int) throws -> Data {
        guard salt.count == saltLen, wrapMaster.count == wrapLen, wrapRecovery.count == wrapLen else {
            throw VaultError.ioError("bad v3 slot header sizes")
        }
        guard headLen + payloadCiphertext.count == slotSize else {
            throw VaultError.ioError("v3 ciphertext must fill slot exactly")
        }
        var data = Data()
        data.append(salt)
        data.append(wrapMaster)
        data.append(wrapRecovery)
        data.append(payloadCiphertext)
        return data
    }

    static func parseSlot(_ slot: Data) -> (salt: Data, wrapMaster: Data, wrapRecovery: Data, ciphertext: Data) {
        let bytes = [UInt8](slot)
        let salt = Data(bytes[0 ..< saltLen])
        let wrapMaster = Data(bytes[saltLen ..< saltLen + wrapLen])
        let wrapRecovery = Data(bytes[saltLen + wrapLen ..< headLen])
        let ciphertext = Data(bytes[headLen ..< bytes.count])
        return (salt, wrapMaster, wrapRecovery, ciphertext)
    }

    /// Формирует внутренний plaintext фиксированного размера innerSize:
    /// len(4,BE) ‖ payloadJSON ‖ случайный паддинг.
    static func makeInner(payloadJSON: Data, innerSize: Int) throws -> Data {
        guard 4 + payloadJSON.count <= innerSize else { throw VaultError.ioError("vault too large for slot") }
        var inner = Data()
        inner += be32(UInt32(payloadJSON.count))
        inner.append(payloadJSON)
        let padLen = innerSize - inner.count
        if padLen > 0 { inner.append(try Random.bytes(padLen)) }
        return inner
    }

    /// Достаёт payloadJSON из расшифрованного внутреннего plaintext.
    static func parseInner(_ inner: Data) -> Data? {
        let bytes = [UInt8](inner)
        guard bytes.count >= 4 else { return nil }
        let len = Int(readBE32(bytes, 0))
        guard len >= 0, 4 + len <= bytes.count else { return nil }
        return Data(bytes[4 ..< 4 + len])
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
