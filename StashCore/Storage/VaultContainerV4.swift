import Foundation

/// Контейнер v4. Как v3, но длина полезной нагрузки хранится в ОТДЕЛЬНОМ блоке,
/// зашифрованном под VK (`lenBlock`), а не заполнением слота. Это позволяет растить
/// контейнер простым ДОПИСЫВАНИЕМ случайных байтов в оба слота: осмысленный префикс
/// каждого слота (включая ложный) не меняется и остаётся дешифруемым своим ключом,
/// при этом оба слота всегда одного размера и открытых полей по-прежнему нет.
///
/// Внешний заголовок: magic(5) version(1) algo(1) iterations(4,BE) slotSize(4,BE) = 15.
/// Слот: salt(16) ‖ wrapMaster(60) ‖ wrapRecovery(60) ‖ lenBlock(32) ‖ ciphertext ‖ random pad.
enum VaultContainerV4 {
    static let magic: [UInt8] = Array("STSH4".utf8)
    static let version: UInt8 = 4
    static let algoPBKDF2: UInt8 = 1

    static let outerHeaderSize = 15
    static let saltLen = 16
    static let wrapLen = 60
    static let lenBlockLen = 32          // AES-GCM(4 байта) = 12+4+16
    static let headLen = 168             // salt + wrapMaster + wrapRecovery + lenBlock

    /// Ступени размера слота: 256 КБ → 1 → 4 → 16 → 64 МБ, далее по 64 МБ; предел 512 МБ.
    static let steps: [Int] = [262_144, 1_048_576, 4_194_304, 16_777_216, 67_108_864]
    static let stepIncrement = 67_108_864
    static let maxSlotSize = 536_870_912 // 512 МБ

    static func isV4(_ data: Data) -> Bool {
        data.count >= magic.count && Array(data.prefix(magic.count)) == magic
    }

    static func immutableMeta(iterations: UInt32) -> Data {
        var b = magic; b.append(version); b.append(algoPBKDF2); b += be32(iterations); return Data(b)
    }

    /// Наименьший размер слота, вмещающий заголовок + шифротекст длины ctLen.
    static func slotSize(forCiphertextLength ctLen: Int) throws -> Int {
        let need = headLen + ctLen
        for s in steps where s >= need { return s }
        if need <= maxSlotSize {
            let over = need - steps.last!
            let extra = ((over + stepIncrement - 1) / stepIncrement) * stepIncrement
            let size = steps.last! + extra
            if size <= maxSlotSize { return size }
        }
        throw VaultError.tooLarge
    }

    static func serialize(iterations: UInt32, slotSize: Int, slot0: Data, slot1: Data) -> Data {
        var b = magic; b.append(version); b.append(algoPBKDF2); b += be32(iterations); b += be32(UInt32(slotSize))
        var data = Data(b); data.append(slot0); data.append(slot1); return data
    }

    struct Container { var iterations: UInt32; var slotSize: Int; var slots: [Data] }

    static func parse(_ data: Data) throws -> Container {
        let bytes = [UInt8](data)
        guard bytes.count >= outerHeaderSize, Array(bytes[0..<magic.count]) == magic else { throw VaultError.corrupted }
        let ver = bytes[5]
        guard ver == version else { throw VaultError.unsupportedVersion(Int(ver)) }
        let iterations = readBE32(bytes, 7)
        let slotSize = Int(readBE32(bytes, 11))
        guard slotSize > headLen, bytes.count >= outerHeaderSize + slotSize * 2 else { throw VaultError.corrupted }
        let s0 = Data(bytes[outerHeaderSize ..< outerHeaderSize + slotSize])
        let s1 = Data(bytes[outerHeaderSize + slotSize ..< outerHeaderSize + 2 * slotSize])
        return Container(iterations: iterations, slotSize: slotSize, slots: [s0, s1])
    }

    static func buildSlot(salt: Data, wrapMaster: Data, wrapRecovery: Data,
                          lenBlock: Data, ciphertext: Data, slotSize: Int) throws -> Data {
        guard salt.count == saltLen, wrapMaster.count == wrapLen, wrapRecovery.count == wrapLen,
              lenBlock.count == lenBlockLen else { throw VaultError.ioError("bad v4 slot sizes") }
        guard headLen + ciphertext.count <= slotSize else { throw VaultError.ioError("v4 slot overflow") }
        var data = Data()
        data.append(salt); data.append(wrapMaster); data.append(wrapRecovery)
        data.append(lenBlock); data.append(ciphertext)
        let pad = slotSize - data.count
        if pad > 0 { data.append(try Random.bytes(pad)) }
        return data
    }

    static func parseSlot(_ slot: Data) -> (salt: Data, wrapMaster: Data, wrapRecovery: Data, lenBlock: Data, body: Data) {
        let b = [UInt8](slot)
        let salt = Data(b[0 ..< saltLen])
        let wrapMaster = Data(b[saltLen ..< saltLen + wrapLen])
        let wrapRecovery = Data(b[saltLen + wrapLen ..< saltLen + 2 * wrapLen])
        let lenBlock = Data(b[saltLen + 2 * wrapLen ..< headLen])
        let body = Data(b[headLen ..< b.count])
        return (salt, wrapMaster, wrapRecovery, lenBlock, body)
    }

    static func encodeLength(_ length: Int) -> Data { Data(be32(UInt32(length))) }
    static func decodeLength(_ data: Data) -> Int? {
        let b = [UInt8](data); guard b.count >= 4 else { return nil }; return Int(readBE32(b, 0))
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private static func readBE32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
}
