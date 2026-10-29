// Wire format of the control protocol realme, OPPO and OnePlus buds share ("OPO"),
// on RFCOMM service 0000079A-….
//
//   AA <len: LEB128> 00 00 <cmd: u16 LE> <seq: u8> <payloadLen: u16 LE> <payload…>
//
// `len` counts everything after itself (7 header bytes + payload). Replies set bit 15 of the
// command; unsolicited pushes use SUBSCRIPTION_RET. There is no checksum.

public struct OPOPacket: Equatable, Sendable {
    public var command: UInt16
    public var seq: UInt8
    public var payload: [UInt8]

    public init(command: UInt16, seq: UInt8 = 0, payload: [UInt8] = []) {
        self.command = command
        self.seq = seq
        self.payload = payload
    }

    public var isResponse: Bool { command & 0x8000 != 0 }

    public func encoded() -> [UInt8] {
        let body = 7 + payload.count
        var out: [UInt8] = [OPOFrame.preamble]
        out += LEB128.encode(UInt(body))
        out += [0x00, 0x00, UInt8(command & 0xFF), UInt8(command >> 8), seq]
        out += [UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        out += payload
        return out
    }
}

enum OPOFrame {
    static let preamble: UInt8 = 0xAA
}

enum LEB128 {
    static func encode(_ value: UInt) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Decodes from `bytes[index...]`; returns the value and bytes consumed, or nil if incomplete.
    static func decode(_ bytes: ArraySlice<UInt8>) -> (value: Int, size: Int)? {
        var result = 0
        var shift = 0
        var size = 0
        for byte in bytes {
            size += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, size) }
            shift += 7
            if shift > 28 { return nil }
        }
        return nil
    }
}

/// Reassembles packets from an RFCOMM byte stream, which may split or merge frames.
public struct OPOFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    /// Upper bound so a corrupt length can't make us buffer forever.
    private static let maxFrame = 4096

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [OPOPacket] {
        buffer += bytes
        var packets: [OPOPacket] = []

        while !buffer.isEmpty {
            guard buffer[0] == OPOFrame.preamble else {
                // Resync on the next preamble.
                if let next = buffer.firstIndex(of: OPOFrame.preamble) {
                    buffer.removeFirst(next)
                } else {
                    buffer.removeAll()
                }
                continue
            }
            guard let (length, lenSize) = LEB128.decode(buffer[1...]) else { break }
            guard length >= 7, length <= Self.maxFrame else {
                buffer.removeFirst()
                continue
            }
            let start = 1 + lenSize
            guard buffer.count >= start + length else { break }

            let body = Array(buffer[start..<(start + length)])
            buffer.removeFirst(start + length)

            let command = UInt16(body[2]) | UInt16(body[3]) << 8
            // The frame length is authoritative: some replies (e.g. spatial audio on the Buds Air 7)
            // declare a longer payload than they carry.
            packets.append(OPOPacket(command: command, seq: body[4], payload: Array(body[7...])))
        }
        return packets
    }
}
