import Testing
@testable import EarshotCore

// Byte strings below were captured from a realme Buds Air 7 (left bud 10%, right bud flat, ANC on).
func bytes(_ hex: String) -> [UInt8] {
    hex.split(whereSeparator: { $0 == " " || $0 == ":" }).map { UInt8($0, radix: 16)! }
}

private func parse(_ hex: String) -> [OPOMessage] {
    var decoder = OPOFrameDecoder()
    return decoder.feed(bytes(hex)).compactMap(OPOParser.parse)
}

@Test func encodesBatteryRequest() {
    let packet = OPOPacket(command: OPOCommand.batteryReq.rawValue, seq: 0)
    #expect(packet.encoded() == bytes("AA 07 00 00 06 01 00 00 00"))
}

@Test func encodesNoiseModeSet() {
    let (cmd, payload) = OPORequest.setNoiseMode(.transparency)
    let packet = OPOPacket(command: cmd.rawValue, seq: 5, payload: payload)
    #expect(packet.encoded() == bytes("AA 0A 00 00 04 04 05 03 00 01 01 02"))
}

@Test func encodesLongFrameLengthAsLEB128() {
    let packet = OPOPacket(command: 0x0105, payload: Array(repeating: 0, count: 200))
    #expect(Array(packet.encoded()[0...2]) == [0xAA, 0xCF, 0x01])
}

@Test func parsesBatteryReplySkippingUnreadableCase() {
    #expect(parse("AA 0D 00 00 06 81 00 06 00 00 02 01 0A 03 00")
            == [.battery([BatteryReading(slot: .left, level: 10, charging: false)])])
}

@Test func parsesChargingFlag() {
    let packet = OPOPacket(command: OPOCommand.batteryReq.reply, payload: [0x00, 0x03, 0x01, 0xD5, 0x02, 0x40, 0x03, 0x37])
    #expect(OPOParser.parse(packet) == .battery([
        BatteryReading(slot: .left, level: 85, charging: true),
        BatteryReading(slot: .right, level: 64, charging: false),
        BatteryReading(slot: .chargingCase, level: 55, charging: false),
    ]))
}

@Test func parsesBatteryAndStatusPushes() {
    #expect(parse("AA 0D 00 00 04 02 8A 06 00 01 02 01 0A 03 00 AA 0F 00 00 04 02 8B 08 00 02 03 01 03 02 00 03 04") == [
        .battery([BatteryReading(slot: .left, level: 10, charging: false)]),
        .placement([.left: .inEar, .right: .inCase]),
    ])
}

@Test func parsesNoiseModeReply() {
    #expect(parse("AA 0B 00 00 0C 81 02 04 00 00 01 01 08") == [.noiseMode(.cancel, level: .deep)])
}

@Test func parsesFirmwareReply() {
    #expect(parse("AA 42 00 00 05 81 03 3B 00 00 06 31 2C 31 2C 31 31 31 2C 31 2C 32 2C 31 2E 31 2E 30 2E 36 32 2C 31 2C 33 2C 31 2E 31 2E 30 2E 36 32 2C 33 2C 31 2C 31 31 31 2C 33 2C 32 2C 30 38 38 2C 33 2C 33 2C 30 38 38")
            == [.firmware("1.1.0.62")])
}

@Test func reassemblesSplitFramesAndSkipsGarbage() {
    var decoder = OPOFrameDecoder()
    let whole = bytes("AA 0B 00 00 0C 81 02 04 00 00 01 01 08")
    #expect(decoder.feed([0x13, 0x37] + Array(whole[0..<5])).isEmpty)
    let packets = decoder.feed(Array(whole[5...]))
    #expect(packets == [OPOPacket(command: 0x810C, seq: 2, payload: [0x00, 0x01, 0x01, 0x08])])
}

@Test func parsesAcks() {
    #expect(OPOParser.parse(OPOPacket(command: OPOCommand.ancConfigSet.reply, payload: [0x00])) == .ack(command: 0x0404, status: 0x00))
    #expect(OPOParser.parse(OPOPacket(command: OPOCommand.miscConfigSet.reply, payload: [0x01])) == .ack(command: 0x0403, status: 0x01))
}

@Test func keepsTheRefusalCodeWhenBudsAreNotWorn() {
    #expect(parse("AA 08 00 00 04 84 43 01 00 0E") == [.ack(command: 0x0404, status: OPOAck.notWorn)])
}

@Test func parsesTouchConfig() {
    guard case let .touch(bindings) = parse("AA 31 00 00 08 81 00 2A 00 00 0A 02 01 01 00 02 01 02 01 02 01 03 06 02 01 04 08 02 01 06 00 01 01 01 00 01 01 02 01 01 01 03 06 01 01 04 08 01 01 06 00").first else {
        Issue.record("not a touch event")
        return
    }
    // Gesture 0x06 isn't one we expose, so 8 of the 10 entries come through.
    #expect(bindings.count == 8)
    #expect(bindings.contains(TouchBinding(side: .left, gesture: .double, action: .playPause)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .triple, action: .next)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .hold, action: .noiseControl)))
    #expect(bindings.contains(TouchBinding(side: .right, gesture: .double, action: .playPause)))
    #expect(bindings.contains(TouchBinding(side: .left, gesture: .single, action: .off)))
}

@Test func encodesTouchSetInTheBudsOwnLayout() {
    let message = OPORequest.setTouch(TouchBinding(side: .left, gesture: .double, action: .next))
    #expect(message?.0 == .touchConfigSet)
    #expect(message?.1 == [0x01, 0x01, 0x01, 0x02, 0x06])
}

@Test func parsesHoldCycleAndAncLevels() {
    #expect(parse("AA 0B 00 00 0C 81 01 04 00 00 02 01 0A AA 0B 00 00 0C 81 02 04 00 00 01 01 20")
            == [.holdCycle([.transparency, .cancel]), .noiseMode(.cancel, level: .adaptive)])
}

@Test func parsesHiResFromMiscReply() {
    #expect(parse("AA 29 00 00 0D 81 04 22 00 00 10 11 00 18 01 1A 01 1B 00 1D 01 1E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
            == [.misc([.multipoint: false, .hiRes: true, .windNoise: true, .spatial: false, .dynamicBass: true])])
}

@Test func parsesEqReplyAndNotify() {
    #expect(parse("AA 09 00 00 0F 81 44 02 00 00 02 AA 08 00 00 04 05 4F 01 00 01") == [.eq(0x02), .eq(0x01)])
}

@Test func encodesEqAndSpatialWrites() {
    let (cmd, payload) = OPORequest.setEq(0x02)
    #expect(OPOPacket(command: cmd.rawValue, seq: 0x43, payload: payload).encoded() == bytes("AA 08 00 00 06 04 43 01 00 02"))
    #expect(OPORequest.setMisc(OPOCode.toggle(.spatial)!, true).1 == [0x1B, 0x01])
    #expect(OPORequest.setSpatialType(true) == (.spatialTypeSet, [0x01]))
}

@Test func keepsSpatialAckWithShortPayload() {
    #expect(parse("AA 08 00 00 1E 84 48 02 00 00") == [.ack(command: 0x041E, status: 0x00)])
}

@Test func parsesNewFeatureSwitches() {
    #expect(parse("AA 11 00 00 0D 81 42 0A 00 00 04 09 00 1B 00 1D 01 1A 01")
            == [.misc([.spatial: false, .dynamicBass: true, .windNoise: true])])
}

@Test func volumeBoostReadAndWrite() {
    #expect(parse("AA 09 00 00 10 81 41 02 00 00 01") == [.volumeBoost(true)])
    #expect(OPORequest.setVolumeBoost(false) == (.volumeBoostSet, [0x00]))
}

// MARK: - Driver

@Test func opoDriverAttributesAcksToTheSettingSent() {
    let driver = OPODriver(companionApp: "realme Link")
    let out = driver.encode(.setNoise(.cancel, level: .mild))
    #expect(out.count == 1)
    let framed = driver.frame(out[0])
    #expect(Array(framed.suffix(3)) == [0x01, 0x01, 0x04])
    // The buds refuse: no bud in an ear.
    let inbound = driver.receive(bytes("AA 08 00 00 04 84 00 01 00 0E"))
    #expect(inbound.replies == [0x8404])
    #expect(inbound.events == [.refused(.noise, code: 0x0E)])
    // And it reads noise mode and wear state back.
    #expect(inbound.send.count == 2)
}

@Test func opoDriverSupersedesQueuedWritesOfTheSameSetting() {
    let driver = OPODriver(companionApp: "realme Link")
    let a = driver.encode(.setEq(1))[0]
    let b = driver.encode(.setEq(2))[0]
    #expect(a.supersedes == b.supersedes)
    #expect(driver.encode(.find(true))[0].supersedes == nil)
}
