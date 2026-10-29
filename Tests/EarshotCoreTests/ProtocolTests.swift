import Testing
@testable import EarshotCore

// Byte strings below were captured from a realme Buds Air 7 (left bud 10%, right bud flat, ANC on).
private func bytes(_ hex: String) -> [UInt8] {
    hex.split(separator: " ").map { UInt8($0, radix: 16)! }
}

@Test func encodesBatteryRequest() {
    let packet = Packet(command: Command.batteryReq.rawValue, seq: 0)
    #expect(packet.encoded() == bytes("AA 07 00 00 06 01 00 00 00"))
}

@Test func encodesNoiseModeSet() {
    let (cmd, payload) = Request.setNoiseMode(.transparency)
    let packet = Packet(command: cmd.rawValue, seq: 5, payload: payload)
    #expect(packet.encoded() == bytes("AA 0A 00 00 04 04 05 03 00 01 01 02"))
}

@Test func encodesLongFrameLengthAsLEB128() {
    let packet = Packet(command: 0x0105, payload: Array(repeating: 0, count: 200))
    #expect(Array(packet.encoded()[0...2]) == [0xAA, 0xCF, 0x01])
}

@Test func parsesBatteryReplySkippingUnreadableCase() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 0D 00 00 06 81 00 06 00 00 02 01 0A 03 00"))
    #expect(packets.count == 1)
    #expect(EventParser.parse(packets[0]) == .battery([BatteryReading(slot: .left, level: 10, charging: false)]))
}

@Test func parsesChargingFlag() {
    let packet = Packet(command: Command.batteryReq.reply, payload: [0x00, 0x03, 0x01, 0xD5, 0x02, 0x40, 0x03, 0x37])
    #expect(EventParser.parse(packet) == .battery([
        BatteryReading(slot: .left, level: 85, charging: true),
        BatteryReading(slot: .right, level: 64, charging: false),
        BatteryReading(slot: .chargingCase, level: 55, charging: false),
    ]))
}

@Test func parsesBatteryAndStatusPushes() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 0D 00 00 04 02 8A 06 00 01 02 01 0A 03 00") + bytes("AA 0F 00 00 04 02 8B 08 00 02 03 01 03 02 00 03 04"))
    #expect(packets.count == 2)
    #expect(EventParser.parse(packets[0]) == .battery([BatteryReading(slot: .left, level: 10, charging: false)]))
    #expect(EventParser.parse(packets[1]) == .placement([.left: .inEar, .right: .inCase]))
}

@Test func parsesNoiseModeReply() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 0B 00 00 0C 81 02 04 00 00 01 01 08"))
    #expect(EventParser.parse(packets[0]) == .noiseMode(.cancel, level: .deep))
}

@Test func parsesFirmwareReply() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 42 00 00 05 81 03 3B 00 00 06 31 2C 31 2C 31 31 31 2C 31 2C 32 2C 31 2E 31 2E 30 2E 36 32 2C 31 2C 33 2C 31 2E 31 2E 30 2E 36 32 2C 33 2C 31 2C 31 31 31 2C 33 2C 32 2C 30 38 38 2C 33 2C 33 2C 30 38 38"))
    #expect(EventParser.parse(packets[0]) == .firmware("1.1.0.62"))
}

@Test func reassemblesSplitFramesAndSkipsGarbage() {
    var decoder = FrameDecoder()
    let whole = bytes("AA 0B 00 00 0C 81 02 04 00 00 01 01 08")
    #expect(decoder.feed([0x13, 0x37] + Array(whole[0..<5])).isEmpty)
    let packets = decoder.feed(Array(whole[5...]))
    #expect(packets == [Packet(command: 0x810C, seq: 2, payload: [0x00, 0x01, 0x01, 0x08])])
}

@Test func parsesAcks() {
    let accepted = Packet(command: Command.ancConfigSet.reply, payload: [0x00])
    let rejected = Packet(command: Command.miscConfigSet.reply, payload: [0x01])
    #expect(EventParser.parse(accepted) == .ack(command: 0x0404, status: 0x00))
    #expect(EventParser.parse(rejected) == .ack(command: 0x0403, status: 0x01))
}

@Test func keepsTheRefusalCodeWhenBudsAreNotWorn() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 08 00 00 04 84 43 01 00 0E"))
    #expect(EventParser.parse(packets[0]) == .ack(command: 0x0404, status: AckStatus.notWorn))
}

@Test func parsesTouchConfig() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 31 00 00 08 81 00 2A 00 00 0A 02 01 01 00 02 01 02 01 02 01 03 06 02 01 04 08 02 01 06 00 01 01 01 00 01 01 02 01 01 01 03 06 01 01 04 08 01 01 06 00"))
    guard case let .touch(bindings) = EventParser.parse(packets[0]) else {
        Issue.record("not a touch event")
        return
    }
    // Gesture 0x06 isn't one we expose, so 8 of the 10 entries come through.
    #expect(bindings.count == 8)
    #expect(bindings.contains(TouchBinding(side: .left, gesture: .double, action: TouchAction.playPause.rawValue)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .triple, action: TouchAction.next.rawValue)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .hold, action: TouchAction.noiseControl.rawValue)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .double, action: TouchAction.playPause.rawValue)))
    #expect(bindings.contains(TouchBinding(side: .left, gesture: .single, action: TouchAction.off.rawValue)))
}

@Test func encodesTouchSetInTheBudsOwnLayout() {
    let (cmd, payload) = Request.setTouch(TouchBinding(side: .left, gesture: .double, action: TouchAction.next.rawValue))
    #expect(cmd == .touchConfigSet)
    #expect(payload == [0x01, 0x01, 0x01, 0x02, 0x06])
}

@Test func parsesHoldCycleAndAncLevels() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 0B 00 00 0C 81 01 04 00 00 02 01 0A") + bytes("AA 0B 00 00 0C 81 02 04 00 00 01 01 20"))
    #expect(EventParser.parse(packets[0]) == .holdCycle([.transparency, .cancel]))
    #expect(EventParser.parse(packets[1]) == .noiseMode(.cancel, level: .adaptive))
}

@Test func parsesHiResFromMiscReply() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 29 00 00 0D 81 04 22 00 00 10 11 00 18 01 1A 01 1B 00 1D 01 1E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))
    #expect(EventParser.parse(packets[0]) == .misc([.multipoint: false, .hiRes: true, .windNoise: true, .spatial: false, .dynamicBass: true]))
}

@Test func parsesEqReplyAndNotify() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 09 00 00 0F 81 44 02 00 00 02") + bytes("AA 08 00 00 04 05 4F 01 00 01"))
    #expect(EventParser.parse(packets[0]) == .eq(.serenade))
    #expect(EventParser.parse(packets[1]) == .eq(.deepBass))
}

@Test func encodesEqAndSpatialWrites() {
    #expect(Packet(command: Request.setEq(.serenade).0.rawValue, seq: 0x43, payload: Request.setEq(.serenade).1).encoded()
            == bytes("AA 08 00 00 06 04 43 01 00 02"))
    #expect(Request.setMisc(.spatial, true).1 == [0x1B, 0x01])
    #expect(Request.setSpatialType(true) == (.spatialTypeSet, [0x01]))
}

@Test func keepsSpatialAckWithShortPayload() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 08 00 00 1E 84 48 02 00 00"))
    #expect(EventParser.parse(packets[0]) == .ack(command: 0x041E, status: 0x00))
}

@Test func parsesNewFeatureSwitches() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 11 00 00 0D 81 42 0A 00 00 04 09 00 1B 00 1D 01 1A 01"))
    #expect(EventParser.parse(packets[0]) == .misc([.spatial: false, .dynamicBass: true, .windNoise: true]))
}

@Test func volumeBoostReadAndWrite() {
    var decoder = FrameDecoder()
    let packets = decoder.feed(bytes("AA 09 00 00 10 81 41 02 00 00 01"))
    #expect(EventParser.parse(packets[0]) == .volumeBoost(true))
    #expect(Request.setVolumeBoost(false) == (.volumeBoostSet, [0x00]))
}
