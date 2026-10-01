import Foundation

/// Бинарный контейнер v2: внешний заголовок + РОВНО ДВА слота одинакового размера.
///
/// Внешний заголовок (общий для обоих слотов) — единственное место, где есть
/// магия/версия. Внутри слота — только длина, соль, обёрнутый VK и шифротекст,
/// добитые криптослучайными байтами до размера слота; неиспользуемый слот —
/// сплошь случайные байты и неотличим от занятого.
///
/// Раскладка:
///   outer: magic(5) version(1) algo(1) iterations(4, BE) slotSize(4, BE)   = 15 байт
///   slot0: [slotSize] ; slot1: [slotSize]
///   внутри слота: L(4, BE) salt(16) wrappedVK(60) ciphertext(L) padding(random)
enum VaultContainer {
    static let magic: [UInt8] = Array("STSH2".utf8)
    static let version: UInt8 = 2
    static let algoPBKDF2: UInt8 = 1

    static let outerHeaderSize = 15
    static let lLen = 4
    static let saltLen = 16
    static let wrappedVKLen = 60          // AES-GCM(32-байтовый VK) = 12+32+16
    static let slotHeaderLen = 80         // 4 + 16 + 60
    static let step = 65536               // 64 КБ

    struct Container {
        var iterations: UInt32
        var slotSize: Int
        var slots: [Data]                 // ровно 2, каждый slotSize байт
    }

    static func isV2(_ data: Data) -> Bool {
        data.count >= magic.count && Array(data.prefix(magic.count)) == magic
    }

    /// Неизменяемая часть метаданных — используется как AAD (без slotSize, т.к. он растёт).
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

    static func parse(_ data: Data) throws -> Container {
        let bytes = [UInt8](data)
        guard bytes.count >= outerHeaderSize, Array(bytes[0..<magic.count]) == magic else {
            throw VaultError.corrupted
        }
        let ver = bytes[5]
        guard ver == version else { throw VaultError.unsupportedVersion(Int(ver)) }
        let iterations = readBE32(bytes, 7)
        let slotSize = Int(readBE32(bytes, 11))
        guard slotSize > slotHeaderLen,
              bytes.count >= outerHeaderSize + slotSize * 2 else {
            throw VaultError.corrupted
        }
        let s0 = Data(bytes[outerHeaderSize ..< outerHeaderSize + slotSize])
        let s1 = Data(bytes[outerHeaderSize + slotSize ..< outerHeaderSize + 2 * slotSize])
        return Container(iterations: iterations, slotSize: slotSize, slots: [s0, s1])
    }

    static func encodeSlot(salt: Data, wrappedVK: Data, ciphertext: Data, slotSize: Int) throws -> Data {
        guard salt.count == saltLen, wrappedVK.count == wrappedVKLen else {
            throw VaultError.ioError("bad slot header sizes")
        }
        let L = ciphertext.count
        guard slotHeaderLen + L <= slotSize else { throw VaultError.ioError("slot overflow") }
        var b = be32(UInt32(L))
        b += [UInt8](salt)
        b += [UInt8](wrappedVK)
        b += [UInt8](ciphertext)
        var data = Data(b)
        let padLen = slotSize - data.count
        if padLen > 0 { data.append(try Random.bytes(padLen)) }
        return data
    }

    static func decodeSlot(_ slot: Data) -> (l: Int, salt: Data, wrappedVK: Data, ciphertext: Data) {
        let bytes = [UInt8](slot)
        let L = Int(readBE32(bytes, 0))
        let salt = Data(bytes[lLen ..< lLen + saltLen])
        let wrapped = Data(bytes[lLen + saltLen ..< slotHeaderLen])
        var ct = Data()
        if L > 0, slotHeaderLen + L <= bytes.count {
            ct = Data(bytes[slotHeaderLen ..< slotHeaderLen + L])
        }
        return (L, salt, wrapped, ct)
    }

    static func slotSize(forCiphertextLength length: Int) -> Int {
        let need = slotHeaderLen + length
        let steps = (need + step - 1) / step
        return max(1, steps) * step
    }

    // MARK: - BE helpers

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
