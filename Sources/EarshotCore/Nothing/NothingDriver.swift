// Nothing Ear and CMF Buds, over RFCOMM service aeac4a03-….
//
//   55 <control: u16 LE> <command: u16 LE> <length: u16 LE> <fsn> <payload…> <crc16: u16 LE>
//
// The CRC (CRC-16/MODBUS over everything before it) is present when control has bit 0x20 set.
// Replies carry the request's command with bit 15 cleared; pushes use their own commands.
// Layouts follow Gadgetbridge, and the tests use its captured messages.

public struct NothingMessage: Equatable, Sendable {
    public var control: UInt16
    public var command: UInt16
    public var fsn: UInt8
    public var payload: [UInt8]

    public init(control: UInt16, command: UInt16, fsn: UInt8 = 0, payload: [UInt8] = []) {
        self.control = control
        self.command = command
        self.fsn = fsn
        self.payload = payload
    }

    var hasCRC: Bool { control & 0x20 != 0 }
    /// Error code in a reply; 0 is success.
    var status: UInt8 { UInt8(control & 0x1F) }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = [0x55] + control.littleEndianBytes + command.littleEndianBytes
            + UInt16(payload.count).littleEndianBytes + [fsn] + payload
        if hasCRC { out += Checksum.crc16Modbus(out).littleEndianBytes }
        return out
    }
}

public struct NothingFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [NothingMessage] {
        buffer += bytes
        var messages: [NothingMessage] = []
        while !buffer.isEmpty {
            guard buffer[0] == 0x55 else {
                buffer.removeFirst(buffer.firstIndex(of: 0x55) ?? buffer.count)
                continue
            }
            guard buffer.count >= 8 else { break }
            let control = u16(buffer[1], buffer[2])
            let length = Int(u16(buffer[5], buffer[6]))
            let crcSize = control & 0x20 != 0 ? 2 : 0
            let total = 8 + length + crcSize
            guard length <= 1024 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }
            // Incoming CRCs aren't checked: captured replies don't always match the outgoing
            // algorithm, and Gadgetbridge ignores them too. The length framing is enough.
            messages.append(NothingMessage(control: control, command: u16(buffer[3], buffer[4]), fsn: buffer[7],
                                           payload: Array(buffer[8..<(8 + length)])))
            buffer.removeFirst(total)
        }
        return messages
    }
}

enum NothingCommand {
    // Requests; replies carry the same command with bit 15 cleared.
    static let battery: UInt16 = 0xC007
    static let firmware: UInt16 = 0xC042
    static let audioMode: UInt16 = 0xC01E
    static let equalizer: UInt16 = 0xC050
    static let ultraBass: UInt16 = 0xC04E
    static let spatial: UInt16 = 0xC04F
    static let lowLatency: UInt16 = 0xC041
    static let tapConfig: UInt16 = 0xC018
    // Pushes.
    static let batteryPush: UInt16 = 0xE001
    static let audioModePush: UInt16 = 0xE003
    // Changes.
    static let find: UInt16 = 0xF002
    static let setTap: UInt16 = 0xF003
    static let setAudioMode: UInt16 = 0xF00F
    static let setEqualizer: UInt16 = 0xF01D
    static let setLowLatency: UInt16 = 0xF040
    static let setUltraBass: UInt16 = 0xF051
    static let setSpatial: UInt16 = 0xF052
}

public final class NothingDriver: Driver {
    public private(set) var capabilities: Capabilities
    private var decoder = NothingFrameDecoder()
    /// Newer models number their messages; older ones always send 0.
    private let numbered: Bool
    private var fsn: UInt8 = 0
    private var battery: [BatterySlot: BatteryReading] = [:]
    private var ultraBassLevel: UInt8 = 4

    public init(name: String) {
        let lower = name.lowercased()
        numbered = lower.contains("ear (a)")
        var caps = Capabilities(companionApp: "Nothing X")
        // Ear (stick) is open-fit: no noise control.
        if !lower.contains("stick") {
            caps.noiseModes = [.off, .transparency, .cancel]
            caps.ancLevels = [.mild, .moderate, .deep]
            caps.adaptiveAnc = !lower.contains("ear (1)")
        }
        if lower.hasPrefix("cmf") {
            caps.eqPresets = [
                EqPreset(0x07, "Dirac", "tuned, balanced"),
                EqPreset(0x01, "Rock", "punchy guitars"),
                EqPreset(0x02, "Electronic", "deep bass, bright top"),
                EqPreset(0x03, "Pop", "vocals and bass"),
                EqPreset(0x04, "Vocals", "voices forward"),
                EqPreset(0x05, "Classical", "wide, natural"),
            ]
        }
        caps.gestures = [.double, .triple, .hold]
        caps.touchActions = [.off, .playPause, .previous, .next, .assistant, .volumeUp, .volumeDown, .noiseControl]
        caps.find = true
        capabilities = caps
    }

    public func start() -> [Outgoing] {
        var out = [request(NothingCommand.firmware), request(NothingCommand.battery, control: 0x5120),
                   request(NothingCommand.lowLatency), request(NothingCommand.ultraBass),
                   request(NothingCommand.spatial), request(NothingCommand.tapConfig)]
        if !capabilities.noiseModes.isEmpty { out.append(request(NothingCommand.audioMode)) }
        if !capabilities.eqPresets.isEmpty { out.append(request(NothingCommand.equalizer)) }
        return out
    }

    public func poll() -> [Outgoing] { [request(NothingCommand.battery, control: 0x5120)] }

    public func encode(_ intent: Intent) -> [Outgoing] {
        switch intent {
        case let .setNoise(mode, level):
            let code: UInt8 = switch mode {
            case .off: 0x05
            case .transparency: 0x07
            case .cancel:
                switch level ?? .deep {
                case .deep: 0x01
                case .moderate: 0x02
                case .mild: 0x03
                case .adaptive: 0x04
                }
            }
            return [change(NothingCommand.setAudioMode, [0x01, code, 0x00], .noise),
                    request(NothingCommand.audioMode)]
        case let .setEq(preset):
            return [change(NothingCommand.setEqualizer, [preset, 0x00], .eq)]
        case let .setToggle(.gameMode, on):
            return [change(NothingCommand.setLowLatency, [on ? 0x01 : 0x02], .toggle(.gameMode))]
        case let .setToggle(.ultraBass, on):
            return [change(NothingCommand.setUltraBass, [on ? 0x01 : 0x00, ultraBassLevel], .toggle(.ultraBass))]
        case let .setToggle(.spatial, on):
            return [change(NothingCommand.setSpatial, [on ? 0x01 : 0x00], .toggle(.spatial))]
        case let .setTouch(binding):
            guard let gesture = Self.gestureCode(binding.gesture), let action = Self.actionCode(binding.action) else { return [] }
            return [change(NothingCommand.setTap, [0x01, binding.side == .left ? 0x02 : 0x03, 0x01, gesture, action], .touch),
                    request(NothingCommand.tapConfig)]
        case let .find(ringing):
            return [change(NothingCommand.find, [ringing ? 0x01 : 0x00], .find)]
        case .refresh:
            return poll()
        case .read(.noise):
            return [request(NothingCommand.audioMode)]
        case .read(.eq):
            return [request(NothingCommand.equalizer)]
        case .read(.touch):
            return [request(NothingCommand.tapConfig)]
        case .setHoldCycle, .setToggle, .read:
            return []
        }
    }

    public func frame(_ message: Outgoing) -> [UInt8] {
        var control = u16(message.body[0], message.body[1])
        if numbered { control |= 0x40 }
        let out = NothingMessage(control: control, command: u16(message.body[2], message.body[3]), fsn: fsn,
                                 payload: Array(message.body[4...])).encoded()
        if numbered { fsn = fsn == 0xFC ? 0 : fsn + 1 }
        return out
    }

    public func receive(_ bytes: [UInt8]) -> Inbound {
        var inbound = Inbound()
        for message in decoder.feed(bytes) {
            let command = message.command | 0x8000
            guard message.status == 0 else { continue }
            inbound.events += events(command: command, message.payload)
        }
        return inbound
    }

    func events(command: UInt16, _ p: [UInt8]) -> [Event] {
        switch command {
        case NothingCommand.battery, NothingCommand.batteryPush:
            // [count, (id, level|charging<<7)…]; ids 2 left, 3 right, 4 case.
            guard let count = p.first, p.count >= 1 + 2 * Int(count) else { return [] }
            for i in 0..<Int(count) {
                let slot: BatterySlot? = switch p[1 + 2 * i] {
                case 0x02: .left
                case 0x03: .right
                case 0x04: .chargingCase
                default: nil
                }
                let raw = p[2 + 2 * i]
                if let slot { battery[slot] = BatteryReading(slot: slot, level: min(Int(raw & 0x7F), 100), charging: raw & 0x80 != 0) }
            }
            return [.battery(Array(battery.values))]
        case NothingCommand.audioMode, NothingCommand.audioModePush:
            // [0x01, mode, 0x00]
            guard p.count >= 3, p[0] == 0x01 else { return [] }
            switch p[1] {
            case 0x05: return [.noiseMode(.off, level: nil)]
            case 0x07: return [.noiseMode(.transparency, level: nil)]
            case 0x01: return [.noiseMode(.cancel, level: .deep)]
            case 0x02: return [.noiseMode(.cancel, level: .moderate)]
            case 0x03: return [.noiseMode(.cancel, level: .mild)]
            case 0x04: return [.noiseMode(.cancel, level: .adaptive)]
            default: return []
            }
        case NothingCommand.equalizer, NothingCommand.setEqualizer | 0x8000:
            return p.first.map { [.eq($0)] } ?? []
        case NothingCommand.ultraBass, NothingCommand.setUltraBass | 0x8000:
            guard let on = p.first else { return [] }
            if p.count >= 2, p[1] > 0 { ultraBassLevel = p[1] }
            return [.toggles([.ultraBass: on == 0x01])]
        case NothingCommand.spatial:
            return p.first.map { [.toggles([.spatial: $0 == 0x01])] } ?? []
        case NothingCommand.lowLatency:
            return p.first.map { [.toggles([.gameMode: $0 == 0x01])] } ?? []
        case NothingCommand.tapConfig:
            return tapConfig(p)
        case NothingCommand.firmware:
            let text = String(decoding: p.filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
            return text.isEmpty ? [] : [.firmware(text)]
        default:
            return []
        }
    }

    // [count, (device, 0x01, gesture, action)…]
    private func tapConfig(_ p: [UInt8]) -> [Event] {
        guard let count = p.first, p.count >= 1 + 4 * Int(count) else { return [] }
        var bindings: [TouchBinding] = []
        for i in 0..<Int(count) {
            let entry = Array(p[(1 + 4 * i)..<(5 + 4 * i)])
            let side: BudSide? = entry[0] == 0x02 ? .left : (entry[0] == 0x03 ? .right : nil)
            guard let side, let gesture = Self.gestures.first(where: { $0.1 == entry[2] })?.0 else { continue }
            bindings.append(TouchBinding(side: side, gesture: gesture,
                                         action: Self.actions.first { $0.1 == entry[3] }?.0 ?? .other(entry[3])))
        }
        return [.touch(bindings)]
    }

    private static let gestures: [(Gesture, UInt8)] = [(.double, 0x02), (.triple, 0x03), (.hold, 0x07)]
    private static func gestureCode(_ gesture: Gesture) -> UInt8? { gestures.first { $0.0 == gesture }?.1 }

    private static let actions: [(TouchAction, UInt8)] = [
        (.off, 0x01), (.playPause, 0x02), (.previous, 0x08), (.next, 0x09), (.assistant, 0x0B),
        (.volumeUp, 0x12), (.volumeDown, 0x13), (.noiseControl, 0x0A),
    ]
    private static func actionCode(_ action: TouchAction) -> UInt8? {
        if case let .other(code) = action { return code }
        return actions.first { $0.0 == action }?.1
    }

    /// Reads go out back to back, as the Nothing X app sends them; models skip ones they lack.
    private func request(_ command: UInt16, control: UInt16 = 0x0120) -> Outgoing {
        Outgoing(body: control.littleEndianBytes + command.littleEndianBytes)
    }

    private func change(_ command: UInt16, _ payload: [UInt8], _ setting: Setting) -> Outgoing {
        Outgoing(body: UInt16(0x0120).littleEndianBytes + command.littleEndianBytes + payload, setting: setting,
                 supersedes: command.littleEndianBytes + (setting == .touch ? Array(payload.prefix(4)) : []),
                 appliedOnWrite: true)
    }
}
