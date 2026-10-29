// Anker soundcore earbuds (Liberty, P and A series), over an RFCOMM service whose UUID starts
// 0cf12d31-fac3-4553-bd80-d6832e7… and ends in the model number.
//
//   host:   EE 08 00 00 00 <command: u16 LE> <length: u16 LE> <payload…> <checksum>
//   device: FF 09 00 00 01 <command: u16 LE> <length: u16 LE> <payload…> <checksum>
//
// `length` counts the whole frame; the checksum is the byte sum of everything before it.
// Layouts follow Gadgetbridge's shared Liberty-family code, which most models use.

public struct SoundcorePacket: Equatable, Sendable {
    public var command: UInt16
    public var payload: [UInt8]

    public init(command: UInt16, payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = [0xEE, 0x08, 0x00, 0x00, 0x00] + command.littleEndianBytes
            + UInt16(10 + payload.count).littleEndianBytes + payload
        out.append(Checksum.sum(out))
        return out
    }
}

public struct SoundcoreFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [SoundcorePacket] {
        buffer += bytes
        var packets: [SoundcorePacket] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0xFF, buffer[1] == 0x09 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 10 else { break }
            let length = Int(u16(buffer[7], buffer[8]))
            guard (10...2048).contains(length), buffer[4] == 0x01 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            packets.append(SoundcorePacket(command: u16(buffer[5], buffer[6]), payload: Array(buffer[9..<(length - 1)])))
            buffer.removeFirst(length)
        }
        return packets
    }
}

enum SoundcoreCommand {
    static let deviceInfo: UInt16 = 0x0101
    static let extendedInfo: UInt16 = 0x0105
    static let sessionInit: UInt16 = 0x8105
    static let batteryNotify: UInt16 = 0x0301
    static let chargingNotify: UInt16 = 0x0401
    static let audioModeNotify: UInt16 = 0x0106
    static let setAudioMode: UInt16 = 0x8106
    static let find: UInt16 = 0x8910
}

public final class SoundcoreDriver: Driver {
    public private(set) var capabilities: Capabilities
    private var decoder = SoundcoreFrameDecoder()
    /// Some models report battery in tenths with an offset, most in fifths.
    private let batteryScale: (multiplier: Int, offset: Int)
    /// Extra bytes some models expect after the audio-mode fields.
    private let audioModeTrailer: [UInt8]
    private var levels: [BatterySlot: Int] = [:]
    private var charging: [BatterySlot: Bool] = [:]
    /// [mode, strength, vocal, adaptive, wind], as last reported; changes resend all of it.
    private var audioMode: [UInt8] = [0x02, 0x10, 0x00, 0x00, 0x00]
    private var knowsAudioMode = false

    public init(name: String) {
        let lower = name.lowercased()
        let tenths = ["aerofit 2", "v20i", "a30i"].contains { lower.contains($0) }
        batteryScale = tenths ? (10, 1) : (20, 0)
        audioModeTrailer = lower.contains("liberty 4 nc") ? [0x01, 0x00] : (lower.contains("liberty") ? [0x01] : [])
        var caps = Capabilities(companionApp: "soundcore")
        caps.find = true
        capabilities = caps
    }

    public func start() -> [Outgoing] {
        [request(SoundcoreCommand.deviceInfo), request(SoundcoreCommand.extendedInfo), request(SoundcoreCommand.sessionInit)]
    }

    public func poll() -> [Outgoing] { [request(SoundcoreCommand.deviceInfo)] }

    public func encode(_ intent: Intent) -> [Outgoing] {
        switch intent {
        case let .setNoise(mode, level):
            var next = audioMode
            next[0] = switch mode {
            case .cancel: 0x00
            case .transparency: 0x01
            case .off: 0x02
            }
            if mode == .cancel, let level {
                next[3] = level == .adaptive ? 0x01 : 0x00
                if let strength = Self.strengths.first(where: { $0.0 == level })?.1 { next[1] = strength }
            }
            return [setAudioMode(next, .noise)]
        case let .setToggle(.windNoise, on):
            var next = audioMode
            next[4] = on ? 0x01 : 0x00
            return [setAudioMode(next, .toggle(.windNoise))]
        case let .find(ringing):
            let on: UInt8 = ringing ? 0x01 : 0x00
            return [Outgoing(body: SoundcorePacket(command: SoundcoreCommand.find, payload: [on, on, 0x00]).encoded(),
                             reply: UInt32(SoundcoreCommand.find), setting: .find, appliedOnWrite: true)]
        case .refresh:
            return poll()
        case .setHoldCycle, .setToggle, .setEq, .setTouch, .read:
            return []
        }
    }

    public func receive(_ bytes: [UInt8]) -> Inbound {
        var inbound = Inbound()
        for packet in decoder.feed(bytes) {
            inbound.replies.append(UInt32(packet.command))
            inbound.events += events(for: packet)
        }
        return inbound
    }

    func events(for packet: SoundcorePacket) -> [Event] {
        let p = packet.payload
        switch packet.command {
        case SoundcoreCommand.deviceInfo where p.count >= 4:
            levels[.left] = scaled(p[2])
            levels[.right] = scaled(p[3])
            var events = [batteryEvent()]
            // Firmware is "NN.NN" at offset 4 or 6, depending on the model.
            for offset in [4, 6] where p.count >= offset + 5 {
                let text = String(decoding: p[offset..<(offset + 5)], as: UTF8.self)
                if Self.isVersion(text) {
                    events.append(.firmware(text))
                    break
                }
            }
            return events
        case SoundcoreCommand.batteryNotify where p.count >= 2:
            levels[.left] = scaled(p[0])
            levels[.right] = scaled(p[1])
            if p.count >= 3 { levels[.chargingCase] = scaled(p[2]) }
            return [batteryEvent()]
        case SoundcoreCommand.chargingNotify where p.count >= 2:
            charging[.left] = p[0] == 0x01
            charging[.right] = p[1] == 0x01
            return [batteryEvent()]
        case SoundcoreCommand.audioModeNotify where p.count >= 5:
            audioMode = Array(p[0..<5])
            var events: [Event] = []
            if !knowsAudioMode {
                // Only models with noise control report an audio mode, so show it from here on.
                knowsAudioMode = true
                capabilities.noiseModes = [.off, .transparency, .cancel]
                capabilities.ancLevels = Self.strengths.map(\.0)
                capabilities.adaptiveAnc = true
                events.append(.capabilities(capabilities))
            }
            let level = p[3] == 0x01 ? AncLevel.adaptive : Self.strengths.first { $0.1 == p[1] & 0xF0 }?.0
            let mode: NoiseMode = switch p[0] {
            case 0x00: .cancel
            case 0x01: .transparency
            default: .off
            }
            events += [.noiseMode(mode, level: mode == .cancel ? level : nil), .toggles([.windNoise: p[4] == 0x01])]
            return events
        default:
            return []
        }
    }

    /// Manual ANC strengths, mildest first.
    private static let strengths: [(AncLevel, UInt8)] = [(.mild, 0x10), (.moderate, 0x20), (.deep, 0x30)]

    private static func isVersion(_ text: String) -> Bool {
        let chars = Array(text)
        return chars.count == 5 && chars[2] == "." && chars.enumerated().allSatisfy { $0.offset == 2 || $0.element.isNumber }
    }

    private func scaled(_ raw: UInt8) -> Int {
        min((Int(raw) + batteryScale.offset) * batteryScale.multiplier, 100)
    }

    private func batteryEvent() -> Event {
        .battery(levels.compactMap { slot, level in
            level > 0 ? BatteryReading(slot: slot, level: level, charging: charging[slot] ?? false) : nil
        })
    }

    private func setAudioMode(_ fields: [UInt8], _ setting: Setting) -> Outgoing {
        Outgoing(body: SoundcorePacket(command: SoundcoreCommand.setAudioMode, payload: fields + audioModeTrailer).encoded(),
                 reply: UInt32(SoundcoreCommand.setAudioMode), setting: setting,
                 supersedes: SoundcoreCommand.setAudioMode.littleEndianBytes, appliedOnWrite: true)
    }

    private func request(_ command: UInt16) -> Outgoing {
        Outgoing(body: SoundcorePacket(command: command).encoded(), reply: UInt32(command))
    }
}
