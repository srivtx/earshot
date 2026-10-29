// Commands and payload layouts of the OPO protocol. Codes match Gadgetbridge's Oppo support
// and were checked against a realme Buds Air 7 (firmware 1.1.0.62).

public enum OPOCommand: UInt16, Sendable {
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

/// Byte codes for the shared model.
enum OPOCode {
    static func side(_ side: BudSide) -> UInt8 { side == .left ? 0x01 : 0x02 }
    static func side(_ code: UInt8) -> BudSide? {
        switch code {
        case 0x01: .left
        case 0x02: .right
        default: nil
        }
    }

    static func slot(_ code: UInt8) -> BatterySlot? {
        switch code {
        case 0x01: .left
        case 0x02: .right
        case 0x03: .chargingCase
        default: nil
        }
    }

    static func placement(_ code: UInt8) -> BudPlacement {
        switch code {
        case 0x00: .inCase
        case 0x01: .outOfEar
        case 0x03: .inEar
        default: .unknown
        }
    }

    /// Noise modes as bits of the hold-cycle mask; also the "set mode" values for off and transparency.
    static func mode(_ mode: NoiseMode) -> UInt8 {
        switch mode {
        case .off: 0x01
        case .transparency: 0x02
        case .cancel: 0x08
        }
    }

    /// While ANC is on, the buds report its strength in place of the plain "on" code.
    static func level(_ level: AncLevel) -> UInt8 {
        switch level {
        case .adaptive: 0x20
        case .deep: 0x08
        case .moderate: 0x10
        case .mild: 0x04
        }
    }

    static let toggles: [(Toggle, UInt8)] = [
        (.gameMode, 0x06),
        (.multipoint, 0x11),
        // High-resolution codec: LHDC on the Buds Air 7; Gadgetbridge calls it LDAC.
        (.hiRes, 0x18),
        (.windNoise, 0x1A),
        (.spatial, 0x1B),
        (.dynamicBass, 0x1D),
    ]
    static func toggle(_ toggle: Toggle) -> UInt8? { toggles.first { $0.0 == toggle }?.1 }
    static func toggle(_ code: UInt8) -> Toggle? { toggles.first { $0.1 == code }?.0 }

    /// On the wire a gesture is the u16 LE `0x<gesture>01`, i.e. bytes `01 <gesture>`.
    static let gestures: [(Gesture, UInt8)] = [(.single, 0x01), (.double, 0x02), (.triple, 0x03), (.hold, 0x04)]
    static func gesture(_ gesture: Gesture) -> UInt8 { gestures.first { $0.0 == gesture }!.1 }
    static func gesture(_ code: UInt8) -> Gesture? { gestures.first { $0.1 == code }?.0 }

    static let actions: [(TouchAction, UInt8)] = [
        (.off, 0x00), (.playPause, 0x01), (.assistant, 0x04), (.previous, 0x05), (.next, 0x06),
        (.noiseControl, 0x08), (.volumeUp, 0x0B), (.volumeDown, 0x0C), (.gameMode, 0x11),
    ]
    static func action(_ action: TouchAction) -> UInt8? {
        if case let .other(code) = action { return code }
        return actions.first { $0.0 == action }?.1
    }
    static func action(_ code: UInt8) -> TouchAction { actions.first { $0.1 == code }?.0 ?? .other(code) }
}

// MARK: - Requests

public enum OPORequest {
    public typealias Message = (OPOCommand, [UInt8])

    public static func battery() -> Message { (.batteryReq, []) }
    public static func earbudsStatus() -> Message { (.earbudsStatusReq, []) }
    public static func firmware() -> Message { (.firmwareReq, []) }

    public static func noiseMode() -> Message { (.ancConfigReq, [0x01, 0x01]) }
    public static func setNoiseMode(_ mode: NoiseMode, level: AncLevel = .deep) -> Message {
        (.ancConfigSet, [0x01, 0x01, mode == .cancel ? OPOCode.level(level) : OPOCode.mode(mode)])
    }

    /// Which modes "touch & hold" cycles through.
    public static func holdCycle() -> Message { (.ancConfigReq, [0x02, 0x01]) }
    public static func setHoldCycle(_ modes: Set<NoiseMode>) -> Message {
        (.ancConfigSet, [0x02, 0x01, modes.reduce(0) { $0 | OPOCode.mode($1) }])
    }

    public static func misc() -> Message {
        (.miscConfigReq, [UInt8(OPOCode.toggles.count)] + OPOCode.toggles.map(\.1))
    }

    public static func setMisc(_ code: UInt8, _ on: Bool) -> Message { (.miscConfigSet, [code, on ? 0x01 : 0x00]) }

    public static func touch() -> Message { (.touchConfigReq, [0x02, 0x03, 0x01]) }
    public static func setTouch(_ binding: TouchBinding) -> Message? {
        guard let action = OPOCode.action(binding.action) else { return nil }
        return (.touchConfigSet, [0x01, OPOCode.side(binding.side), 0x01, OPOCode.gesture(binding.gesture), action])
    }

    public static func eq() -> Message { (.eqReq, []) }
    public static func setEq(_ preset: UInt8) -> Message { (.eqSet, [preset]) }
    /// Volume enhancer ("high volume" in realme Link). Not feature switch 0x09, which is vocal enhancement.
    public static func volumeBoost() -> Message { (.volumeBoostReq, []) }
    public static func setVolumeBoost(_ on: Bool) -> Message { (.volumeBoostSet, [on ? 0x01 : 0x00]) }
    /// Sent alongside the spatial feature switch, as realme Link does.
    public static func setSpatialType(_ on: Bool) -> Message { (.spatialTypeSet, [on ? 0x01 : 0x00]) }

    public static func findDevice(_ ringing: Bool) -> Message { (.findDevice, [ringing ? 0x01 : 0x00]) }

    /// Ask for pushes of battery, wear status, ANC, game mode and multipoint changes.
    public static func subscribe() -> Message { (.subscriptionSet, [0x09, 0x01, 0x02, 0x03, 0x05, 0x06]) }
}

/// Status bytes the buds put in a set command's reply.
public enum OPOAck {
    public static let ok: UInt8 = 0x00
    /// The Buds Air 7 refuse noise-control changes with this while no bud is in an ear.
    public static let notWorn: UInt8 = 0x0E
}

// MARK: - Replies

public enum OPOMessage: Equatable, Sendable {
    case battery([BatteryReading])
    case placement([BudSide: BudPlacement])
    case noiseMode(NoiseMode, level: AncLevel?)
    case holdCycle(Set<NoiseMode>)
    case misc([Toggle: Bool])
    case touch([TouchBinding])
    case eq(UInt8)
    case volumeBoost(Bool)
    case firmware(String)
    /// A set command's result. Status 0 is success; see `OPOAck` for known refusals.
    case ack(command: UInt16, status: UInt8)
}

public enum OPOParser {
    public static func parse(_ packet: OPOPacket) -> OPOMessage? {
        let p = packet.payload
        switch packet.command {
        case OPOCommand.batteryReq.reply:
            return battery(p)
        case OPOCommand.earbudsStatusReq.reply:
            return placement(p)
        case OPOCommand.ancConfigReq.reply:
            return anc(p)
        case OPOCommand.miscConfigReq.reply:
            return misc(p)
        case OPOCommand.touchConfigReq.reply:
            return touch(p)
        case OPOCommand.firmwareReq.reply:
            return firmware(p)
        case OPOCommand.eqReq.reply:
            return p.count >= 2 && p[0] == 0x00 ? .eq(p[1]) : nil
        case OPOCommand.volumeBoostReq.reply:
            return p.count >= 2 && p[0] == 0x00 ? .volumeBoost(p[1] == 0x01) : nil
        case OPOCommand.eqNotify.rawValue:
            let id = p.count >= 2 && p[0] == 0x00 ? p[1] : p.first
            return id.map(OPOMessage.eq)
        case OPOCommand.ancConfigSet.reply, OPOCommand.miscConfigSet.reply, OPOCommand.touchConfigSet.reply,
             OPOCommand.eqSet.reply, OPOCommand.spatialTypeSet.reply, OPOCommand.volumeBoostSet.reply,
             OPOCommand.findDevice.reply, OPOCommand.subscriptionSet.reply:
            return .ack(command: packet.command & 0x7FFF, status: p.first ?? 0xFF)
        case OPOCommand.subscriptionRet.rawValue:
            return push(p)
        default:
            return nil
        }
    }

    /// Pushes start with a subscription type byte where replies have a status byte;
    /// the rest of the layout is the same.
    private static func push(_ p: [UInt8]) -> OPOMessage? {
        switch p.first {
        case 0x01: return battery(p)
        case 0x02: return placement(p)
        case 0x03: return anc(p)
        case 0x05 where p.count == 2: return .misc([.gameMode: p[1] == 0x01])
        default: return nil
        }
    }

    // [status, count, (slot, level|charging<<7)…]
    private static func battery(_ p: [UInt8]) -> OPOMessage? {
        guard p.count >= 2 else { return nil }
        var readings: [BatteryReading] = []
        var i = 2
        while i + 1 < p.count {
            defer { i += 2 }
            guard p[i] != 0xFF, let slot = OPOCode.slot(p[i]) else { continue }
            let level = Int(p[i + 1] & 0x7F)
            let charging = p[i + 1] & 0x80 != 0
            // The case reports 0 when it can't be read (lid closed, buds out).
            if slot == .chargingCase, level == 0, !charging { continue }
            readings.append(BatteryReading(slot: slot, level: min(level, 100), charging: charging))
        }
        return .battery(readings)
    }

    // [status, count, (side, placement)…]; side 3 is the case and is ignored.
    private static func placement(_ p: [UInt8]) -> OPOMessage? {
        guard p.count >= 2 else { return nil }
        var map: [BudSide: BudPlacement] = [:]
        var i = 2
        while i + 1 < p.count {
            if let side = OPOCode.side(p[i]) { map[side] = OPOCode.placement(p[i + 1]) }
            i += 2
        }
        return .placement(map)
    }

    // [status, type, (0x01)?, value]. Type 0x01 is the current mode, 0x02 the hold-cycle mask.
    private static func anc(_ p: [UInt8]) -> OPOMessage? {
        guard p.count >= 3, let value = p.last else { return nil }
        switch p[1] {
        case 0x01:
            if value == OPOCode.mode(.off) { return .noiseMode(.off, level: nil) }
            if value == OPOCode.mode(.transparency) { return .noiseMode(.transparency, level: nil) }
            if let level = AncLevel.allCases.first(where: { OPOCode.level($0) == value }) {
                return .noiseMode(.cancel, level: level)
            }
            return nil
        case 0x02:
            let modes = Set(NoiseMode.allCases.filter { value & OPOCode.mode($0) != 0 })
            return modes.count >= 2 ? .holdCycle(modes) : nil
        default:
            return nil
        }
    }

    // [status, count, (setting, value)…]
    private static func misc(_ p: [UInt8]) -> OPOMessage? {
        guard p.count >= 2 else { return nil }
        var map: [Toggle: Bool] = [:]
        var i = 2
        while i + 1 < p.count {
            if let toggle = OPOCode.toggle(p[i]) { map[toggle] = p[i + 1] == 0x01 }
            i += 2
        }
        return .misc(map)
    }

    // [status, count, (side, 0x01, gesture, action)…]
    private static func touch(_ p: [UInt8]) -> OPOMessage? {
        guard p.count >= 2, (p.count - 2) % 4 == 0 else { return nil }
        var bindings: [TouchBinding] = []
        var i = 2
        while i + 3 < p.count {
            if let side = OPOCode.side(p[i]), p[i + 1] == 0x01, let gesture = OPOCode.gesture(p[i + 2]) {
                bindings.append(TouchBinding(side: side, gesture: gesture, action: OPOCode.action(p[i + 3])))
            }
            i += 4
        }
        return .touch(bindings)
    }

    // [status, count, ascii "side,kind,value,side,kind,value,…"]; kind 2 is the firmware version.
    private static func firmware(_ p: [UInt8]) -> OPOMessage? {
        guard p.count > 2 else { return nil }
        let text = String(decoding: p[2...], as: UTF8.self)
        let fields = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 2 < fields.count {
            if fields[i + 1] == "2", fields[i + 2].contains(".") { return .firmware(fields[i + 2]) }
            i += 3
        }
        return fields.first(where: { $0.contains(".") }).map(OPOMessage.firmware)
    }
}
