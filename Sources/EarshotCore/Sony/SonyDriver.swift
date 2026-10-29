// Sony headphones and earbuds (WH-1000XM, WF-1000XM, LinkBuds and others), over RFCOMM service
// 96CC203E-… (older models) or 956C7B26-… (newer).
//
//   3E <type> <seq> <length: u32 BE> <payload…> <checksum> 3C
//
// Everything between the markers is escaped: 3C, 3D and 3E become 3D followed by the byte with
// bit 4 cleared. The checksum is the byte sum of type through payload. Every command is
// acknowledged with an ACK carrying the next sequence number. Layouts follow Gadgetbridge.

public struct SonyMessage: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case ack = 0x01
        case command1 = 0x0C
        case command2 = 0x0E
    }

    public var kind: Kind
    public var seq: UInt8
    public var payload: [UInt8]

    public init(kind: Kind, seq: UInt8, payload: [UInt8] = []) {
        self.kind = kind
        self.seq = seq
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let count = UInt32(payload.count)
        var body: [UInt8] = [kind.rawValue, seq, UInt8(count >> 24), UInt8((count >> 16) & 0xFF),
                             UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
        body += payload
        body.append(Checksum.sum(body))
        return [0x3E] + Self.escape(body) + [0x3C]
    }

    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { [0x3C, 0x3D, 0x3E].contains($0) ? [0x3D, $0 & 0xEF] : [$0] }
    }

    static func unescape(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var escaped = false
        for byte in bytes {
            if escaped {
                out.append(byte | 0x10)
                escaped = false
            } else if byte == 0x3D {
                escaped = true
            } else {
                out.append(byte)
            }
        }
        return out
    }
}

public struct SonyFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [SonyMessage] {
        buffer += bytes
        var messages: [SonyMessage] = []
        while let start = buffer.firstIndex(of: 0x3E) {
            guard let end = buffer[(start + 1)...].firstIndex(of: 0x3C) else {
                buffer.removeFirst(start)
                break
            }
            let body = SonyMessage.unescape(buffer[(start + 1)..<end])
            buffer.removeFirst(end + 1)
            guard body.count >= 7, Checksum.sum(body.dropLast()) == body.last,
                  let kind = SonyMessage.Kind(rawValue: body[0]) else { continue }
            let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
            guard length == body.count - 7 else { continue }
            messages.append(SonyMessage(kind: kind, seq: body[1], payload: Array(body[6..<(6 + length)])))
        }
        if buffer.count > 4096 { buffer.removeAll() }
        return messages
    }
}

public final class SonyDriver: Driver {
    public private(set) var capabilities: Capabilities
    private var decoder = SonyFrameDecoder()
    private var seq: UInt8 = 0
    /// Set from the init reply: version 1 (WH-1000XM3 era) or 2 (WF-1000XM4 onward).
    private(set) var version: Int?
    private var battery: [BatterySlot: BatteryReading] = [:]
    /// The ambient-control variant byte the buds answered with, which a change has to repeat.
    private var ambientVariant: UInt8?
    private var ambientHasWind = false
    private var focusOnVoice: UInt8 = 0
    private var ambientLevel: UInt8 = 10

    /// Every command waits for the transport ACK.
    static let ackKey: UInt32 = 1

    public init(headphones: Bool) {
        var caps = Capabilities(companionApp: "Sony | Sound Connect")
        caps.kind = headphones ? .headphones : .earbuds
        caps.noiseModes = [.off, .transparency, .cancel]
        caps.eqPresets = [
            EqPreset(0x00, "Off", "flat, as mastered"),
            EqPreset(0x16, "Bass boost", "more low end"),
            EqPreset(0x10, "Bright", "crisp, airy highs"),
            EqPreset(0x11, "Excited", "lively, V-shaped"),
            EqPreset(0x12, "Mellow", "soft, warm"),
            EqPreset(0x13, "Relaxed", "laid-back"),
            EqPreset(0x14, "Vocal", "voices forward"),
            EqPreset(0x15, "Treble boost", "more sparkle"),
            EqPreset(0x17, "Speech", "for podcasts and calls"),
        ]
        capabilities = caps
    }

    public func start() -> [Outgoing] {
        [command([0x00, 0x00])]
    }

    public func poll() -> [Outgoing] { batteryRequests() }

    public func encode(_ intent: Intent) -> [Outgoing] {
        guard let version else { return [] }
        switch intent {
        case let .setNoise(mode, _):
            return [command(setAmbient(mode, version: version), .noise)]
        case let .setEq(preset):
            return [command([0x58, version == 1 ? 0x01 : 0x00, preset, 0x00], .eq)]
        case .refresh:
            return batteryRequests()
        case .read(.noise):
            return ambientRequests(version: version)
        case .read(.eq):
            return [command([0x56, version == 1 ? 0x01 : 0x00])]
        case .setHoldCycle, .setToggle, .setTouch, .find, .read:
            return []
        }
    }

    public func frame(_ message: Outgoing) -> [UInt8] {
        SonyMessage(kind: SonyMessage.Kind(rawValue: message.body[0]) ?? .command1, seq: seq,
                    payload: Array(message.body[1...])).encoded()
    }

    public func receive(_ bytes: [UInt8]) -> Inbound {
        var inbound = Inbound()
        for message in decoder.feed(bytes) {
            switch message.kind {
            case .ack:
                // A repeated ACK carries the number we already have.
                guard message.seq != seq else { continue }
                seq = message.seq
                inbound.replies.append(Self.ackKey)
            case .command1, .command2:
                inbound.immediate.append(SonyMessage(kind: .ack, seq: 1 &- message.seq).encoded())
                handle(message.payload, into: &inbound)
            }
        }
        return inbound
    }

    private func handle(_ p: [UInt8], into inbound: inout Inbound) {
        guard let code = p.first else { return }
        switch code {
        case 0x01 where version == nil:
            // Init reply: its length tells the protocol version.
            version = p.count == 8 ? 2 : 1
            let version = version!
            inbound.send = [command([0x04, 0x02])] + batteryRequests() + ambientRequests(version: version)
                + [command([0x56, version == 1 ? 0x01 : 0x00])]
        case 0x05 where p.count > 3 && p[1] == 0x02:
            let text = String(decoding: p[3...], as: UTF8.self)
            if !text.isEmpty { inbound.events.append(.firmware(text)) }
        case 0x11, 0x13, 0x23, 0x25:
            // Battery reply and notify codes moved between versions.
            let codes: [UInt8] = version == 1 ? [0x11, 0x13] : [0x23, 0x25]
            if codes.contains(code), battery(p) { inbound.events.append(.battery(Array(battery.values))) }
        case 0x67, 0x69:
            inbound.events += ambient(p)
        case 0x57, 0x59:
            if p.count >= 3 { inbound.events.append(.eq(p[2])) }
        default:
            break
        }
    }

    // [code, type, level, charging, (level, charging)]
    private func battery(_ p: [UInt8]) -> Bool {
        guard p.count >= 4, let version else { return false }
        func reading(_ slot: BatterySlot, _ level: UInt8, _ charging: UInt8) {
            battery[slot] = (1...100).contains(level) ? BatteryReading(slot: slot, level: Int(level), charging: charging == 1) : nil
        }
        switch (version, p[1]) {
        case (_, 0x00):
            reading(.single, p[2], p[3])
        case (1, 0x01), (2, 0x01), (2, 0x09):
            guard p.count >= 6 else { return false }
            reading(.left, p[2], p[3])
            reading(.right, p[4], p[5])
        case (1, 0x02), (2, 0x0A):
            reading(.chargingCase, p[2], p[3])
        default:
            return false
        }
        return true
    }

    private func ambient(_ p: [UInt8]) -> [Event] {
        guard let version, p.count >= 6 else { return [] }
        let on: Bool
        let ambient: Bool
        if version == 1 {
            // [code, 02, on, wind?, mode, 01, focus, level]
            guard p.count == 8 else { return [] }
            on = p[2] != 0
            ambientHasWind = p[3] == 0x02
            ambient = p[4] == 0
            ambientVariant = 0x02
        } else {
            // [code, variant, ?, on, mode, (wind), focus, level]
            guard [0x15, 0x17, 0x22].contains(p[1]) else { return [] }
            ambientVariant = p[1]
            ambientHasWind = p[1] == 0x17 && p.count > 7
            on = p[3] != 0
            ambient = p[1] == 0x22 || p[4] == 1
        }
        focusOnVoice = p[p.count - 2]
        ambientLevel = p[p.count - 1]
        var events: [Event] = []
        // Variant 0x22 is ambient sound without noise cancelling.
        if p[1] == 0x22, capabilities.noiseModes.contains(.cancel) {
            capabilities.noiseModes = [.off, .transparency]
            events.append(.capabilities(capabilities))
        }
        events.append(.noiseMode(!on ? .off : (ambient ? .transparency : .cancel), level: nil))
        return events
    }

    private func setAmbient(_ mode: NoiseMode, version: Int) -> [UInt8] {
        let level = mode == .cancel ? 0 : ambientLevel
        if version == 1 {
            let modeByte: UInt8 = mode == .cancel ? (ambientHasWind ? 2 : 1) : 0
            return [0x68, 0x02, mode == .off ? 0x00 : 0x11, ambientHasWind ? 0x02 : 0x00, modeByte, 0x01, focusOnVoice, level]
        }
        var out: [UInt8] = [0x68, ambientVariant ?? 0x17, 0x01, mode == .off ? 0 : 1, mode == .transparency ? 1 : 0]
        if ambientHasWind { out.append(0x02) }
        return out + [focusOnVoice, ambientLevel]
    }

    private func batteryRequests() -> [Outgoing] {
        guard let version else { return [] }
        let code: UInt8 = version == 1 ? 0x10 : 0x22
        if capabilities.kind == .headphones { return [command([code, 0x00])] }
        // Newer earbuds answer one of the two dual-battery variants.
        let types: [UInt8] = version == 1 ? [0x01, 0x02] : [0x09, 0x01, 0x0A]
        return types.map { command([code, $0]) }
    }

    private func ambientRequests(version: Int) -> [Outgoing] {
        version == 1 ? [command([0x66, 0x02])] : [command([0x66, 0x17]), command([0x66, 0x15])]
    }

    private func command(_ payload: [UInt8], _ setting: Setting? = nil) -> Outgoing {
        Outgoing(body: [SonyMessage.Kind.command1.rawValue] + payload, reply: Self.ackKey, setting: setting,
                 supersedes: setting == nil ? nil : Array(payload.prefix(2)), appliedOnWrite: setting != nil)
    }
}
