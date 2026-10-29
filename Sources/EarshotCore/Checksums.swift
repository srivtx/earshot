enum Checksum {
    /// CRC-16/XMODEM (poly 0x1021, init 0), used by Samsung.
    static func crc16Xmodem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// CRC-16/MODBUS (reflected poly 0xA001, init 0xFFFF), used by Nothing.
    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// Sum of all bytes, truncated, used by Sony and Soundcore.
    static func sum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, &+)
    }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}

func u16(_ lo: UInt8, _ hi: UInt8) -> UInt16 { UInt16(lo) | UInt16(hi) << 8 }
