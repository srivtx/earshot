/// realme, OPPO and OnePlus buds. One request at a time; each set command is acknowledged
/// with a status byte.
public final class OPODriver: Driver {
    public private(set) var capabilities: Capabilities
    private var decoder = OPOFrameDecoder()
    private var seq: UInt8 = 0
    /// ANC strength to use when ANC is turned on without one.
    private var lastLevel: AncLevel = .deep
    /// Which setting the last write of each command was for, to attribute its acknowledgement.
    private var lastSetting: [UInt16: Setting] = [:]

    /// `knownToggles` are the settings the model is known to have; others appear once reported.
    public init(companionApp: String, knownToggles: [Toggle] = []) {
        var caps = Capabilities(companionApp: companionApp)
        caps.toggles = knownToggles
        caps.noiseModes = [.off, .transparency, .cancel]
        caps.ancLevels = [.mild, .moderate, .deep]
        caps.adaptiveAnc = true
        caps.noiseNeedsWear = true
        caps.holdCycle = [.off, .transparency, .cancel]
        caps.eqPresets = [
            EqPreset(0x00, "Original", "flat, as mastered"),
            EqPreset(0x01, "Deep bass", "heavy low end"),
            EqPreset(0x02, "Serenade", "warm, vocal-forward"),
            EqPreset(0x03, "Clear bass", "tight, punchy lows"),
        ]
        caps.gestures = [.double, .triple, .hold, .single]
        caps.touchActions = [.off, .playPause, .assistant, .previous, .next, .noiseControl,
                             .volumeUp, .volumeDown, .gameMode]
        caps.find = true
        capabilities = caps
    }

    public func start() -> [Outgoing] {
        // Subscribing is never acknowledged (pushes just start), so it gets a gap instead of a reply.
        [Outgoing(body: Self.body(OPORequest.subscribe()))]
            + [OPORequest.battery(), OPORequest.earbudsStatus(), OPORequest.noiseMode(), OPORequest.holdCycle(),
               OPORequest.misc(), OPORequest.firmware(), OPORequest.touch(), OPORequest.eq(), OPORequest.volumeBoost()]
            .map { request($0) }
    }

    public func poll() -> [Outgoing] {
        [request(OPORequest.battery()), request(OPORequest.earbudsStatus())]
    }

    public func encode(_ intent: Intent) -> [Outgoing] {
        switch intent {
        case let .setNoise(mode, level):
            let level = level ?? lastLevel
            return [request(OPORequest.setNoiseMode(mode, level: level), .noise)]
        case let .setHoldCycle(modes):
            return [request(OPORequest.setHoldCycle(modes), .holdCycle)]
        case let .setToggle(.volumeBoost, on):
            return [request(OPORequest.setVolumeBoost(on), .toggle(.volumeBoost))]
        case let .setToggle(toggle, on):
            guard let code = OPOCode.toggle(toggle) else { return [] }
            var out = [request(OPORequest.setMisc(code, on), .toggle(toggle))]
            if toggle == .spatial { out.append(request(OPORequest.setSpatialType(on))) }
            return out
        case let .setEq(preset):
            return [request(OPORequest.setEq(preset), .eq)]
        case let .setTouch(binding):
            return OPORequest.setTouch(binding).map { [request($0, .touch)] } ?? []
        case let .find(ringing):
            return [request(OPORequest.findDevice(ringing), .find)]
        case .refresh:
            return [request(OPORequest.battery()), request(OPORequest.earbudsStatus()), request(OPORequest.noiseMode())]
        case let .read(setting):
            return reads(for: setting)
        }
    }

    public func frame(_ message: Outgoing) -> [UInt8] {
        let command = u16(message.body[0], message.body[1])
        if let setting = message.setting { lastSetting[command] = setting }
        defer { seq &+= 1 }
        return OPOPacket(command: command, seq: seq, payload: Array(message.body[2...])).encoded()
    }

    public func receive(_ bytes: [UInt8]) -> Inbound {
        var inbound = Inbound()
        for packet in decoder.feed(bytes) {
            if packet.isResponse { inbound.replies.append(UInt32(packet.command)) }
            guard let message = OPOParser.parse(packet) else { continue }
            switch message {
            case let .battery(readings): inbound.events.append(.battery(readings))
            case let .placement(map): inbound.events.append(.placement(map))
            case let .noiseMode(mode, level):
                if let level, level != .adaptive { lastLevel = level }
                inbound.events.append(.noiseMode(mode, level: level))
            case let .holdCycle(modes): inbound.events.append(.holdCycle(modes))
            case let .misc(map): inbound.events.append(.toggles(map))
            case let .touch(bindings): inbound.events.append(.touch(bindings))
            case let .eq(preset): inbound.events.append(.eq(preset))
            case let .volumeBoost(on): inbound.events.append(.toggles([.volumeBoost: on]))
            case let .firmware(version): inbound.events.append(.firmware(version))
            case let .ack(command, status): acknowledge(command, status, into: &inbound)
            }
        }
        return inbound
    }

    private func acknowledge(_ command: UInt16, _ status: UInt8, into inbound: inout Inbound) {
        guard let setting = lastSetting[command] else { return }
        let ok = status == OPOAck.ok
        inbound.events.append(ok ? .applied(setting) : .refused(setting, code: status))
        switch setting {
        // Read back, so what's shown is what the buds actually hold.
        case .touch, .toggle(.volumeBoost): inbound.send += reads(for: setting)
        case .noise, .holdCycle, .toggle, .eq: if !ok { inbound.send += reads(for: setting) }
        case .find: break
        }
    }

    private func reads(for setting: Setting) -> [Outgoing] {
        switch setting {
        case .noise: [request(OPORequest.noiseMode()), request(OPORequest.earbudsStatus())]
        case .holdCycle: [request(OPORequest.holdCycle())]
        case .toggle(.volumeBoost): [request(OPORequest.volumeBoost())]
        case .toggle: [request(OPORequest.misc())]
        case .eq: [request(OPORequest.eq())]
        case .touch: [request(OPORequest.touch())]
        case .find: []
        }
    }

    private static func body(_ message: OPORequest.Message) -> [UInt8] {
        message.0.rawValue.littleEndianBytes + message.1
    }

    private func request(_ message: OPORequest.Message, _ setting: Setting? = nil) -> Outgoing {
        let (command, payload) = message
        // A newer request for the same setting supersedes one still waiting. The last payload
        // byte is the value, so everything before it identifies the setting.
        let key = command == .findDevice ? nil : command.rawValue.littleEndianBytes + payload.dropLast()
        return Outgoing(body: Self.body(message), reply: UInt32(command.reply), setting: setting, supersedes: key)
    }
}
