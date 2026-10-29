// Commands and typed messages for realme / Oppo earbuds.
// Command codes and payload layouts match Gadgetbridge's Oppo support and were checked
// against a realme Buds Air 7 (firmware 1.1.0.62).

public enum Command: UInt16, Sendable {
    case findDevice = 0x0400
    case touchConfigSet = 0x0401
    case eqSet = 0x0406
    case volumeBoostSet = 0x0407
    case spatialTypeSet = 0x041E
    case miscConfigSet = 0x0403
    case ancConfigSet = 0x0404
    case firmwareReq = 0x0105
    case batteryReq = 0x0106
    case touchConfigReq = 0x0108
    case earbudsStatusReq = 0x0109
    case eqReq = 0x010F
    case volumeBoostReq = 0x0110
    case ancConfigReq = 0x010C
    case miscConfigReq = 0x010D
    case subscriptionRet = 0x0204
    case subscriptionSet = 0x0205
    case eqNotify = 0x0504

    /// The command a reply to this request carries.
    public var reply: UInt16 { rawValue | 0x8000 }
}

// MARK: - Model

public enum BatterySlot: UInt8, Sendable, CaseIterable {
    case left = 1, right = 2, chargingCase = 3
}

public struct BatteryReading: Equatable, Sendable {
    public var slot: BatterySlot
    public var level: Int
    public var charging: Bool

    public init(slot: BatterySlot, level: Int, charging: Bool) {
        self.slot = slot
        self.level = level
        self.charging = charging
    }
}

public enum BudSide: UInt8, Sendable, CaseIterable {
    case left = 1, right = 2
}

public enum BudPlacement: Equatable, Sendable {
    case inCase, outOfEar, inEar, unknown(UInt8)

    init(code: UInt8) {
        switch code {
        case 0x00: self = .inCase
        case 0x01: self = .outOfEar
        case 0x03: self = .inEar
        default: self = .unknown(code)
        }
    }
}

public enum NoiseMode: UInt8, Sendable, CaseIterable {
    case off = 0x01
    case transparency = 0x02
    case cancel = 0x08
}

/// ANC strength. While ANC is on, the buds report one of these in place of the plain "on" code.
public enum AncLevel: UInt8, Sendable, CaseIterable {
    case adaptive = 0x20
    case deep = 0x08
    case moderate = 0x10
    case mild = 0x04
}

public enum MiscSetting: UInt8, Sendable, CaseIterable {
    case gameMode = 0x06
    case multipoint = 0x11
    /// High-resolution codec (LHDC on the Buds Air 7; Gadgetbridge calls it LDAC).
    case hiRes = 0x18
    case windNoise = 0x1A
    case spatial = 0x1B
    case dynamicBass = 0x1D
}

public enum EqPreset: UInt8, Sendable, CaseIterable {
    case original = 0x00
    case deepBass = 0x01
    case serenade = 0x02
    case clearBass = 0x03
}

/// Touch gestures. On the wire a gesture is the u16 LE `0x<gesture>01`, i.e. bytes `01 <gesture>`.
public enum Gesture: UInt8, Sendable, CaseIterable {
    case single = 0x01
    case double = 0x02
    case triple = 0x03
    case hold = 0x04
}

public enum TouchAction: UInt8, Sendable, CaseIterable {
    case off = 0x00
    case playPause = 0x01
    case assistant = 0x04
    case previous = 0x05
    case next = 0x06
    case noiseControl = 0x08
    case volumeUp = 0x0B
    case volumeDown = 0x0C
    case gameMode = 0x11
}

/// One gesture's binding. `action` stays raw so codes we don't know survive a round trip.
public struct TouchBinding: Equatable, Sendable {
    public var side: BudSide
    public var gesture: Gesture
    public var action: UInt8

    public init(side: BudSide, gesture: Gesture, action: UInt8) {
        self.side = side
        self.gesture = gesture
        self.action = action
    }
}

// MARK: - Requests

public enum Request {
    public static func battery() -> (Command, [UInt8]) { (.batteryReq, []) }
    public static func earbudsStatus() -> (Command, [UInt8]) { (.earbudsStatusReq, []) }
    public static func firmware() -> (Command, [UInt8]) { (.firmwareReq, []) }

    public static func noiseMode() -> (Command, [UInt8]) { (.ancConfigReq, [0x01, 0x01]) }
    public static func setNoiseMode(_ mode: NoiseMode) -> (Command, [UInt8]) { (.ancConfigSet, [0x01, 0x01, mode.rawValue]) }
    /// Turns ANC on at a given strength.
    public static func setAncLevel(_ level: AncLevel) -> (Command, [UInt8]) { (.ancConfigSet, [0x01, 0x01, level.rawValue]) }

    /// Which modes "touch & hold" cycles through.
    public static func holdCycle() -> (Command, [UInt8]) { (.ancConfigReq, [0x02, 0x01]) }
    public static func setHoldCycle(_ modes: Set<NoiseMode>) -> (Command, [UInt8]) {
        (.ancConfigSet, [0x02, 0x01, modes.reduce(0) { $0 | $1.rawValue }])
    }

    public static func misc(_ settings: [MiscSetting]) -> (Command, [UInt8]) {
        (.miscConfigReq, [UInt8(settings.count)] + settings.map(\.rawValue))
    }

    public static func setMisc(_ setting: MiscSetting, _ on: Bool) -> (Command, [UInt8]) {
        (.miscConfigSet, [setting.rawValue, on ? 0x01 : 0x00])
    }

    public static func touch() -> (Command, [UInt8]) { (.touchConfigReq, [0x02, 0x03, 0x01]) }
    public static func setTouch(_ binding: TouchBinding) -> (Command, [UInt8]) {
        (.touchConfigSet, [0x01, binding.side.rawValue, 0x01, binding.gesture.rawValue, binding.action])
    }

    public static func eq() -> (Command, [UInt8]) { (.eqReq, []) }
    /// Volume enhancer ("high volume" in realme Link). Not the 0x09 feature switch, which is vocal enhancement.
    public static func volumeBoost() -> (Command, [UInt8]) { (.volumeBoostReq, []) }
    public static func setVolumeBoost(_ on: Bool) -> (Command, [UInt8]) { (.volumeBoostSet, [on ? 0x01 : 0x00]) }
    public static func setEq(_ preset: EqPreset) -> (Command, [UInt8]) { (.eqSet, [preset.rawValue]) }
    /// Sent alongside the spatial feature switch, as realme Link does.
    public static func setSpatialType(_ on: Bool) -> (Command, [UInt8]) { (.spatialTypeSet, [on ? 0x01 : 0x00]) }

    public static func findDevice(_ ringing: Bool) -> (Command, [UInt8]) { (.findDevice, [ringing ? 0x01 : 0x00]) }

    /// Ask for pushes of battery, wear status, ANC, game mode and multipoint changes.
    public static func subscribe() -> (Command, [UInt8]) { (.subscriptionSet, [0x09, 0x01, 0x02, 0x03, 0x05, 0x06]) }
}

/// Status bytes the buds put in a set command's reply.
public enum AckStatus {
    public static let ok: UInt8 = 0x00
    /// Seen on the Buds Air 7 when changing noise control with no bud in an ear.
    public static let notWorn: UInt8 = 0x0E
}

// MARK: - Replies

public enum Event: Equatable, Sendable {
    case battery([BatteryReading])
    case placement([BudSide: BudPlacement])
    /// `level` is set when ANC is on and the buds reported its strength.
    case noiseMode(NoiseMode, level: AncLevel?)
    case holdCycle(Set<NoiseMode>)
    case misc([MiscSetting: Bool])
    case touch([TouchBinding])
    case eq(EqPreset)
    case volumeBoost(Bool)
    case firmware(String)
    /// A set command's result. Status 0 is success; see `AckStatus` for known refusals.
    case ack(command: UInt16, status: UInt8)
}

public enum EventParser {
    public static func parse(_ packet: Packet) -> Event? {
        let p = packet.payload
        switch packet.command {
        case Command.batteryReq.reply:
            return battery(p)
        case Command.earbudsStatusReq.reply:
            return placement(p)
        case Command.ancConfigReq.reply:
            return anc(p)
        case Command.miscConfigReq.reply:
            return misc(p)
        case Command.touchConfigReq.reply:
            return touch(p)
        case Command.firmwareReq.reply:
            return firmware(p)
        case Command.eqReq.reply:
            return p.count >= 2 && p[0] == 0x00 ? EqPreset(rawValue: p[1]).map(Event.eq) : nil
        case Command.volumeBoostReq.reply:
            return p.count >= 2 && p[0] == 0x00 ? .volumeBoost(p[1] == 0x01) : nil
        case Command.eqNotify.rawValue:
            let id = p.count >= 2 && p[0] == 0x00 ? p[1] : p.first
            return id.flatMap(EqPreset.init(rawValue:)).map(Event.eq)
        case Command.ancConfigSet.reply, Command.miscConfigSet.reply, Command.touchConfigSet.reply,
             Command.eqSet.reply, Command.spatialTypeSet.reply, Command.volumeBoostSet.reply,
             Command.findDevice.reply, Command.subscriptionSet.reply:
            return .ack(command: packet.command & 0x7FFF, status: p.first ?? 0xFF)
        case Command.subscriptionRet.rawValue:
            return push(p)
        default:
            return nil
        }
    }

    /// Pushes start with a subscription type byte where replies have a status byte;
    /// the rest of the layout is the same.
    private static func push(_ p: [UInt8]) -> Event? {
        switch p.first {
        case 0x01: return battery(p)
        case 0x02: return placement(p)
        case 0x03: return anc(p)
        case 0x05 where p.count == 2: return .misc([.gameMode: p[1] == 0x01])
        default: return nil
        }
    }

    // [status, count, (slot, level|charging<<7)…]
    private static func battery(_ p: [UInt8]) -> Event? {
        guard p.count >= 2 else { return nil }
        var readings: [BatteryReading] = []
        var i = 2
        while i + 1 < p.count {
            defer { i += 2 }
            guard p[i] != 0xFF, let slot = BatterySlot(rawValue: p[i]) else { continue }
            let level = Int(p[i + 1] & 0x7F)
            let charging = p[i + 1] & 0x80 != 0
            // The case reports 0 when it can't be read (lid closed, buds out).
            if slot == .chargingCase, level == 0, !charging { continue }
            readings.append(BatteryReading(slot: slot, level: min(level, 100), charging: charging))
        }
        return .battery(readings)
    }

    // [status, count, (side, placement)…]; side 3 is the case and is ignored.
    private static func placement(_ p: [UInt8]) -> Event? {
        guard p.count >= 2 else { return nil }
        var map: [BudSide: BudPlacement] = [:]
        var i = 2
        while i + 1 < p.count {
            if let side = BudSide(rawValue: p[i]) { map[side] = BudPlacement(code: p[i + 1]) }
            i += 2
        }
        return .placement(map)
    }

    // [status, type, (0x01)?, value]. Type 0x01 is the current mode, 0x02 the hold-cycle mask.
    private static func anc(_ p: [UInt8]) -> Event? {
        guard p.count >= 3, let value = p.last else { return nil }
        switch p[1] {
        case 0x01:
            if value == NoiseMode.off.rawValue { return .noiseMode(.off, level: nil) }
            if value == NoiseMode.transparency.rawValue { return .noiseMode(.transparency, level: nil) }
            if let level = AncLevel(rawValue: value) { return .noiseMode(.cancel, level: level) }
            return nil
        case 0x02:
            let modes = Set(NoiseMode.allCases.filter { value & $0.rawValue == $0.rawValue })
            return modes.count >= 2 ? .holdCycle(modes) : nil
        default:
            return nil
        }
    }

    // [status, count, (setting, value)…]
    private static func misc(_ p: [UInt8]) -> Event? {
        guard p.count >= 2 else { return nil }
        var map: [MiscSetting: Bool] = [:]
        var i = 2
        while i + 1 < p.count {
            if let setting = MiscSetting(rawValue: p[i]) { map[setting] = p[i + 1] == 0x01 }
            i += 2
        }
        return .misc(map)
    }

    // [status, count, (side, 0x01, gesture, action)…]
    private static func touch(_ p: [UInt8]) -> Event? {
        guard p.count >= 2, (p.count - 2) % 4 == 0 else { return nil }
        var bindings: [TouchBinding] = []
        var i = 2
        while i + 3 < p.count {
            if let side = BudSide(rawValue: p[i]), p[i + 1] == 0x01, let gesture = Gesture(rawValue: p[i + 2]) {
                bindings.append(TouchBinding(side: side, gesture: gesture, action: p[i + 3]))
            }
            i += 4
        }
        return .touch(bindings)
    }

    // [status, count, ascii "side,kind,value,side,kind,value,…"]; kind 2 is the firmware version.
    private static func firmware(_ p: [UInt8]) -> Event? {
        guard p.count > 2 else { return nil }
        let text = String(decoding: p[2...], as: UTF8.self)
        let fields = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 2 < fields.count {
            if fields[i + 1] == "2", fields[i + 2].contains(".") { return .firmware(fields[i + 2]) }
            i += 3
        }
        return fields.first(where: { $0.contains(".") }).map(Event.firmware)
    }
}
