// Samsung Galaxy Buds+ and later, over RFCOMM service 2e73a4ad-… (Buds2 onward) or plain SPP.
//
//   FD <header: u16 LE> <id> <payload…> <crc16: u16 LE> DD
//
// The header's low 10 bits count the id, payload and CRC. The CRC is CRC-16/XMODEM over the id
// and payload. Layouts follow GalaxyBudsClient and Gadgetbridge, and the status tests use
// messages captured from real buds.

public enum GalaxyModel: Sendable, CaseIterable {
    case budsPlus, budsLive, budsPro, buds2, buds2Pro, budsFE, buds3, buds3Pro, buds3FE, budsCore, buds4, buds4Pro
}

enum GalaxyID {
    static let statusUpdated: UInt8 = 0x60
    static let extendedStatusUpdated: UInt8 = 0x61
    static let noiseControlsUpdate: UInt8 = 0x77
    static let noiseControls: UInt8 = 0x78
    static let ambientMode: UInt8 = 0x80
    static let ambientModeUpdated: UInt8 = 0x81
    static let adjustSoundSync: UInt8 = 0x85
    static let equalizer: UInt8 = 0x86
    static let managerInfo: UInt8 = 0x88
    static let touchpadOption: UInt8 = 0x92
    static let noiseReduction: UInt8 = 0x98
    static let noiseReductionUpdate: UInt8 = 0x9B
    static let findStart: UInt8 = 0xA0
    static let findStop: UInt8 = 0xA1
}

public struct GalaxyMessage: Equatable, Sendable {
    public var id: UInt8
    public var payload: [UInt8]

    public init(id: UInt8, payload: [UInt8] = []) {
        self.id = id
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let body = [id] + payload
        let size = UInt16(body.count + 2)
        return [0xFD] + size.littleEndianBytes + body + Checksum.crc16Xmodem(body).littleEndianBytes + [0xDD]
    }
}

public struct GalaxyFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [GalaxyMessage] {
        buffer += bytes
        var messages: [GalaxyMessage] = []
        while !buffer.isEmpty {
            guard buffer[0] == 0xFD else {
                buffer.removeFirst(buffer.firstIndex(of: 0xFD) ?? buffer.count)
                continue
            }
            guard buffer.count >= 3 else { break }
            let size = Int(u16(buffer[1], buffer[2]) & 0x3FF)
            let total = 3 + size + 1
            guard size >= 3 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }
            let body = Array(buffer[3..<(3 + size - 2)])
            let crc = u16(buffer[3 + size - 2], buffer[3 + size - 1])
            guard buffer[total - 1] == 0xDD, Checksum.crc16Xmodem(body) == crc else {
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(total)
            messages.append(GalaxyMessage(id: body[0], payload: Array(body[1...])))
        }
        return messages
    }
}

public final class GalaxyDriver: Driver {
    public private(set) var capabilities: Capabilities
    private let model: GalaxyModel
    private var decoder = GalaxyFrameDecoder()
    /// Touch & hold is set for both buds at once, so keep both.
    private var holdAction: [BudSide: UInt8] = [:]

    public init(model: GalaxyModel) {
        self.model = model
        var caps = Capabilities(companionApp: "Galaxy Wearable")
        switch model {
        case .budsPlus: caps.noiseModes = [.off, .transparency]
        case .budsLive: caps.noiseModes = [.off, .cancel]
        default: caps.noiseModes = [.off, .transparency, .cancel]
        }
        caps.adaptiveAnc = model == .buds3Pro || model == .buds4Pro
        caps.eqPresets = [
            EqPreset(0, "Normal", "flat, as mastered"),
            EqPreset(1, "Bass boost", "more low end"),
            EqPreset(2, "Soft", "gentle, relaxed"),
            EqPreset(3, "Dynamic", "punchy, lively"),
            EqPreset(4, "Clear", "crisp vocals"),
            EqPreset(5, "Treble boost", "brighter highs"),
        ]
        caps.toggles = [.gameMode]
        if Self.usesStandardTouchMap(model) {
            caps.gestures = [.hold]
            caps.touchActions = [.assistant, .noiseControl, .volume, .spotify]
        }
        caps.find = true
        capabilities = caps
    }

    private static func usesStandardTouchMap(_ model: GalaxyModel) -> Bool {
        model != .budsPlus && model != .budsLive
    }

    public func start() -> [Outgoing] {
        // Introduce ourselves as a manager; the buds push their full status on connect regardless.
        [message(GalaxyID.managerInfo, [0x01, 0x01, 34])]
    }

    /// The buds push status changes on their own, so there's nothing to poll.
    public func poll() -> [Outgoing] { [] }

    public func encode(_ intent: Intent) -> [Outgoing] {
        switch intent {
        case let .setNoise(mode, level):
            switch model {
            case .budsPlus:
                return [message(GalaxyID.ambientMode, [mode == .transparency ? 1 : 0], .noise)]
            case .budsLive:
                return [message(GalaxyID.noiseReduction, [mode == .cancel ? 1 : 0], .noise)]
            default:
                let code: UInt8 = switch mode {
                case .off: 0
                case .cancel where level == .adaptive && capabilities.adaptiveAnc: 3
                case .cancel: 1
                case .transparency: 2
                }
                return [message(GalaxyID.noiseControls, [code], .noise)]
            }
        case let .setToggle(.gameMode, on):
            return [message(GalaxyID.adjustSoundSync, [on ? 1 : 0], .toggle(.gameMode))]
        case let .setEq(preset):
            return [message(GalaxyID.equalizer, [preset], .eq)]
        case let .setTouch(binding):
            guard binding.gesture == .hold, let code = Self.touchCode(binding.action) else { return [] }
            holdAction[binding.side] = code
            let left = holdAction[.left] ?? code
            let right = holdAction[.right] ?? code
            return [message(GalaxyID.touchpadOption, [left, right], .touch)]
        case let .find(ringing):
            return [message(ringing ? GalaxyID.findStart : GalaxyID.findStop, [], .find)]
        case .setHoldCycle, .setToggle, .refresh, .read:
            return []
        }
    }

    public func receive(_ bytes: [UInt8]) -> Inbound {
        var inbound = Inbound()
        for message in decoder.feed(bytes) {
            inbound.events += events(for: message)
        }
        return inbound
    }

    func events(for message: GalaxyMessage) -> [Event] {
        let p = message.payload
        switch message.id {
        case GalaxyID.extendedStatusUpdated where model == .budsPlus && p.count >= 14:
            return status(left: p[2], right: p[3], placement: p[6], case: p[7])
                + [.noiseMode(p[8] == 1 ? .transparency : .off, level: nil),
                   .toggles([.gameMode: p[10] == 1]), .eq(p[11])]
        case GalaxyID.extendedStatusUpdated where p.count >= 13:
            var events = status(left: p[2], right: p[3], placement: p[6], case: p[7])
            events += [.toggles([.gameMode: p[8] == 1]), .eq(p[9])]
            if Self.usesStandardTouchMap(model) {
                holdAction = [.left: p[11] >> 4, .right: p[11] & 0x0F]
                events.append(.touch(holdBindings()))
            }
            events.append(model == .budsLive ? .noiseMode(p[12] == 1 ? .cancel : .off, level: nil) : noise(p[12]))
            return events
        case GalaxyID.statusUpdated where p.count >= 7:
            return status(left: p[1], right: p[2], placement: p[5], case: p[6])
        case GalaxyID.noiseControlsUpdate where !p.isEmpty:
            return [noise(p[0])]
        case GalaxyID.ambientModeUpdated where !p.isEmpty:
            return [.noiseMode(p[0] == 1 ? .transparency : .off, level: nil)]
        case GalaxyID.noiseReductionUpdate where !p.isEmpty:
            return [.noiseMode(p[0] == 1 ? .cancel : .off, level: nil)]
        default:
            return []
        }
    }

    private func status(left: UInt8, right: UInt8, placement: UInt8, case caseLevel: UInt8) -> [Event] {
        var readings: [BatteryReading] = []
        for (slot, level) in [(BatterySlot.left, left), (.right, right), (.chargingCase, caseLevel)]
        where (1...100).contains(level) {
            readings.append(BatteryReading(slot: slot, level: Int(level), charging: false))
        }
        return [.battery(readings),
                .placement([.left: Self.placement(placement >> 4), .right: Self.placement(placement & 0x0F)])]
    }

    private func noise(_ code: UInt8) -> Event {
        switch code {
        case 1: .noiseMode(.cancel, level: nil)
        case 2: .noiseMode(.transparency, level: nil)
        case 3: .noiseMode(.cancel, level: .adaptive)
        default: .noiseMode(.off, level: nil)
        }
    }

    private static func placement(_ code: UInt8) -> BudPlacement {
        switch code {
        case 1: .inEar
        case 2: .outOfEar
        case 3, 4: .inCase
        default: .unknown
        }
    }

    private static let touchCodes: [(TouchAction, UInt8)] = [(.assistant, 1), (.noiseControl, 2), (.volume, 3), (.spotify, 4)]
    private static func touchCode(_ action: TouchAction) -> UInt8? {
        if case let .other(code) = action { return code }
        return touchCodes.first { $0.0 == action }?.1
    }

    private func holdBindings() -> [TouchBinding] {
        holdAction.map { side, code in
            TouchBinding(side: side, gesture: .hold, action: Self.touchCodes.first { $0.1 == code }?.0 ?? .other(code))
        }
    }

    private func message(_ id: UInt8, _ payload: [UInt8], _ setting: Setting? = nil) -> Outgoing {
        // The buds don't confirm changes; the next status push shows the outcome.
        Outgoing(body: GalaxyMessage(id: id, payload: payload).encoded(), setting: setting,
                 supersedes: [id], appliedOnWrite: setting != nil)
    }
}
