import Testing
@testable import EarshotCore

// Captured messages from other projects' test data: GalaxyBudsClient (Samsung extended status
// from real buds) and Gadgetbridge (Sony and Nothing). Where a vector is only a payload, the frame
// around it is built here.

// MARK: - Profiles

@Test func matchesBudsByName() {
    #expect(Profiles.match(name: "realme Buds Air 7")?.brand == .realme)
    #expect(Profiles.match(name: "realme Buds Air 7")?.tested == true)
    #expect(Profiles.match(name: "realme Buds Air7")?.tested == true)
    #expect(Profiles.match(name: "realme Buds Air 7 Pro")?.tested == false)
    #expect(Profiles.match(name: "realme Buds T310")?.tested == false)
    #expect(Profiles.match(name: "OPPO Enco Air3 Pro")?.brand == .oppo)
    #expect(Profiles.match(name: "OnePlus Buds 3")?.brand == .oneplus)
    #expect(Profiles.match(name: "Galaxy Buds2 Pro (A1B2)")?.brand == .samsung)
    #expect(Profiles.match(name: "WH-1000XM5")?.brand == .sony)
    #expect(Profiles.match(name: "LinkBuds S")?.brand == .sony)
    #expect(Profiles.match(name: "Nothing Ear (2)")?.brand == .nothing)
    #expect(Profiles.match(name: "CMF Buds Pro 2")?.brand == .nothing)
    #expect(Profiles.match(name: "soundcore Liberty 4 NC")?.brand == .soundcore)
    #expect(Profiles.match(name: "soundcore Space One") == nil)
    #expect(Profiles.match(name: "AirPods Pro") == nil)
    #expect(Profiles.match(name: "Redmi Buds 5 Pro") == nil)
}

@Test func tellsGalaxyModelsApart() {
    #expect(Profiles.galaxyModel("galaxy buds2 pro (a1b2)") == .buds2Pro)
    #expect(Profiles.galaxyModel("galaxy buds2 (a1b2)") == .buds2)
    #expect(Profiles.galaxyModel("galaxy buds3 pro") == .buds3Pro)
    #expect(Profiles.galaxyModel("galaxy buds+ (a1b2)") == .budsPlus)
    #expect(Profiles.galaxyModel("buds pro") == .budsPro)
    #expect(Profiles.galaxyModel("galaxy buds (a1b2)") == nil)
}

@Test func parsesUUIDs() {
    #expect(Profiles.uuid("0000079a-d102-11e1-9b23-00025b00a5a5")
            == [0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1, 0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5])
}

// MARK: - Samsung

private let buds2ProStatus = "fd3100610d046464010033580001bf220001460146010000033500030010010101013203010101000cae0100030001000101b637dd"
private let buds2Status = "fd2810610a0364640101113300033f2201003c013c0102000366000100100000000011020101000000bea3dd"
private let budsPlusStatus = "fd1b10610d00575401001165000000030022010401040100000003001e55dd"
private let budsLiveStatus = "fd1c106109010f610100116400000022010017011701000003001000000281dd"

private func hexBytes(_ hex: String) -> [UInt8] {
    let chars = Array(hex.utf8)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(decoding: chars[$0...($0 + 1)], as: UTF8.self), radix: 16)! }
}

@Test func decodesCapturedGalaxyFrames() {
    var decoder = GalaxyFrameDecoder()
    let messages = decoder.feed(hexBytes(buds2ProStatus) + hexBytes(buds2Status))
    #expect(messages.map(\.id) == [0x61, 0x61])
    #expect(messages[0].payload.count == 46)
}

@Test func galaxyBuds2ProStatusInCase() {
    let events = GalaxyDriver(model: .buds2Pro).receive(hexBytes(buds2ProStatus)).events
    #expect(events.contains(.battery([BatteryReading(slot: .left, level: 100, charging: false),
                                      BatteryReading(slot: .right, level: 100, charging: false),
                                      BatteryReading(slot: .chargingCase, level: 88, charging: false)])))
    #expect(events.contains(.placement([.left: .inCase, .right: .inCase])))
    #expect(events.contains(.eq(1)))
    #expect(events.contains(.noiseMode(.off, level: nil)))
    #expect(events.contains(.toggles([.gameMode: false])))
    guard case let .touch(bindings) = events.first(where: { if case .touch = $0 { true } else { false } }) else {
        Issue.record("no touch event")
        return
    }
    #expect(Set(bindings.map(\.action)) == [.noiseControl])
}

@Test func galaxyBuds2StatusWornWithAnc() {
    let events = GalaxyDriver(model: .buds2).receive(hexBytes(buds2Status)).events
    #expect(events.contains(.placement([.left: .inEar, .right: .inEar])))
    #expect(events.contains(.noiseMode(.cancel, level: nil)))
    #expect(events.contains(.eq(3)))
}

@Test func galaxyBudsPlusAndLiveUseTheirOwnLayouts() {
    let plus = GalaxyDriver(model: .budsPlus).receive(hexBytes(budsPlusStatus)).events
    #expect(plus.contains(.eq(3)))
    #expect(plus.contains(.noiseMode(.off, level: nil)))
    let live = GalaxyDriver(model: .budsLive).receive(hexBytes(budsLiveStatus)).events
    #expect(live.contains(.noiseMode(.cancel, level: nil)))
}

@Test func galaxyEncodesWithChecksum() {
    let driver = GalaxyDriver(model: .buds2Pro)
    let frame = driver.frame(driver.encode(.setNoise(.transparency, level: nil))[0])
    var decoder = GalaxyFrameDecoder()
    #expect(decoder.feed(frame) == [GalaxyMessage(id: 0x78, payload: [0x02])])
    #expect(frame.first == 0xFD && frame.last == 0xDD)
}

@Test func galaxySetsHoldForBothBudsAtOnce() {
    let driver = GalaxyDriver(model: .buds2Pro)
    _ = driver.receive(hexBytes(buds2ProStatus))
    let out = driver.encode(.setTouch(TouchBinding(side: .left, gesture: .hold, action: .volume)))
    var decoder = GalaxyFrameDecoder()
    #expect(decoder.feed(driver.frame(out[0])) == [GalaxyMessage(id: 0x92, payload: [0x03, 0x02])])
}

// MARK: - Sony

@Test func sonyEncodesEqLikeGadgetbridge() {
    // From Gadgetbridge's v2 test: EQ "Bright" with sequence number 1.
    let message = SonyMessage(kind: .command1, seq: 1, payload: bytes("58:00:10:00"))
    #expect(message.encoded() == bytes("3e:0c:01:00:00:00:04:58:00:10:00:79:3c"))
}

@Test func sonyEscapesMarkerBytes() {
    let message = SonyMessage(kind: .command1, seq: 0, payload: [0x3C, 0x3D, 0x3E])
    let encoded = message.encoded()
    #expect(!encoded.dropFirst().dropLast().contains(0x3C))
    var decoder = SonyFrameDecoder()
    #expect(decoder.feed(encoded) == [message])
}

@Test func sonyParsesEqNotify() {
    var decoder = SonyFrameDecoder()
    let messages = decoder.feed(bytes("3e:0c:01:00:00:00:0a:59:00:16:06:11:0a:0a:0a:0a:0a:cf:3c"))
    #expect(messages == [SonyMessage(kind: .command1, seq: 1, payload: bytes("59:00:16:06:11:0a:0a:0a:0a:0a"))])
}

@Test func sonyHandshakeAcksAndPicksVersion() {
    let driver = SonyDriver(headphones: false)
    let initFrame = driver.frame(driver.start()[0])
    #expect(initFrame == SonyMessage(kind: .command1, seq: 0, payload: [0x00, 0x00]).encoded())

    // The buds ACK with the next sequence number, then send an 8-byte init reply (version 2).
    var inbound = driver.receive(SonyMessage(kind: .ack, seq: 1).encoded())
    #expect(inbound.replies == [SonyDriver.ackKey])
    inbound = driver.receive(SonyMessage(kind: .command1, seq: 0, payload: bytes("01:00:03:00:10:04:00:00")).encoded())
    #expect(inbound.immediate == [SonyMessage(kind: .ack, seq: 1).encoded()])
    #expect(driver.version == 2)
    // Firmware, three battery reads, two ambient reads and EQ.
    #expect(inbound.send.count == 7)
    // Later commands carry the sequence number from the last ACK.
    #expect(driver.frame(inbound.send[0]) == SonyMessage(kind: .command1, seq: 1, payload: [0x04, 0x02]).encoded())
}

@Test func sonyReadsBatteryAndAmbient() {
    let driver = SonyDriver(headphones: false)
    _ = driver.receive(SonyMessage(kind: .command1, seq: 0, payload: bytes("01:00:03:00:10:04:00:00")).encoded())
    let battery = driver.receive(SonyMessage(kind: .command1, seq: 1, payload: bytes("23:09:46:00:50:01")).encoded())
    guard case let .battery(readings) = battery.events.first else {
        Issue.record("no battery event")
        return
    }
    #expect(Set(readings.map(\.level)) == [70, 80])
    #expect(readings.first { $0.slot == .right }?.charging == true)

    // Ambient sound on, level 20, as in Gadgetbridge's v2 vectors.
    let ambient = driver.receive(SonyMessage(kind: .command1, seq: 0, payload: bytes("69:17:01:01:01:00:14")).encoded())
    #expect(ambient.events == [.noiseMode(.transparency, level: nil)])
    // Switching to ANC keeps the variant and level the buds reported.
    let out = driver.encode(.setNoise(.cancel, level: nil))
    #expect(Array(out[0].body.dropFirst()) == bytes("68:17:01:01:00:00:14"))
}

@Test func sonyV1AmbientMatchesGadgetbridge() {
    let driver = SonyDriver(headphones: true)
    _ = driver.receive(SonyMessage(kind: .command1, seq: 0, payload: bytes("01:00:40:10")).encoded())
    _ = driver.receive(SonyMessage(kind: .command1, seq: 1, payload: bytes("67:02:01:00:00:01:00:05")).encoded())
    #expect(Array(driver.encode(.setNoise(.cancel, level: nil))[0].body.dropFirst()) == bytes("68:02:11:00:01:01:00:00"))
    #expect(Array(driver.encode(.setNoise(.off, level: nil))[0].body.dropFirst()) == bytes("68:02:00:00:00:01:00:05"))
}

// MARK: - Nothing

@Test func nothingDecodesCapturedEqualizer() {
    // Gadgetbridge: equalizer status, Classical (0x05).
    let driver = NothingDriver(name: "CMF Buds Pro 2")
    #expect(driver.receive(bytes("55 60 01 50 40 01 00 60 05 7f 43")).events == [.eq(0x05)])
}

@Test func nothingDecodesCapturedUltraBass() {
    let driver = NothingDriver(name: "CMF Buds Pro 2")
    #expect(driver.receive(bytes("55 60 01 4e 40 02 00 1b 00 02 80 71")).events == [.toggles([.ultraBass: false])])
}

@Test func nothingEncodesEqualizerLikeGadgetbridge() {
    // Gadgetbridge's vector was taken with a numbered (ear (a)-style) device at sequence 0x14.
    let message = NothingMessage(control: 0x0160, command: 0xF01D, fsn: 0x14, payload: [0x02, 0x00])
    #expect(message.encoded() == bytes("55 60 01 1d f0 02 00 14 02 00 eb cd"))
}

@Test func nothingDecodesBatteryAndNoise() {
    let driver = NothingDriver(name: "Nothing Ear (2)")
    let battery = NothingMessage(control: 0x0120, command: 0x4007, payload: [0x03, 0x02, 0x50, 0x03, 0xD5, 0x04, 0x20]).encoded()
    guard case let .battery(readings) = driver.receive(battery).events.first else {
        Issue.record("no battery event")
        return
    }
    #expect(readings.contains(BatteryReading(slot: .right, level: 85, charging: true)))
    #expect(readings.count == 3)
    let mode = NothingMessage(control: 0x0120, command: 0x401E, payload: [0x01, 0x03, 0x00]).encoded()
    #expect(driver.receive(mode).events == [.noiseMode(.cancel, level: .mild)])
}

@Test func nothingNumbersMessagesOnlyWhereNeeded() {
    let ear2 = NothingDriver(name: "Nothing Ear (2)")
    let first = ear2.frame(ear2.encode(.find(true))[0])
    let second = ear2.frame(ear2.encode(.find(false))[0])
    #expect(first[7] == 0 && second[7] == 0)
    let earA = NothingDriver(name: "Nothing Ear (a)")
    _ = earA.frame(earA.encode(.find(true))[0])
    #expect(earA.frame(earA.encode(.find(false))[0])[7] == 1)
}

// MARK: - soundcore

@Test func soundcoreFramesWithSumChecksum() {
    let frame = SoundcorePacket(command: 0x0101).encoded()
    #expect(frame == [0xEE, 0x08, 0x00, 0x00, 0x00, 0x01, 0x01, 0x0A, 0x00, 0x02])
}

@Test func soundcoreReadsBatteryInFifths() {
    // Gadgetbridge: battery notify [1, 2, 3] is 20%, 40% and 60% for left, right and case.
    let driver = SoundcoreDriver(name: "soundcore Liberty 4 NC")
    let frame: [UInt8] = [0xFF, 0x09, 0x00, 0x00, 0x01, 0x01, 0x03, 0x0D, 0x00, 0x01, 0x02, 0x03, 0x00]
    guard case let .battery(readings) = driver.receive(frame).events.first else {
        Issue.record("no battery event")
        return
    }
    #expect(Set(readings.map(\.level)) == [20, 40, 60])
}

@Test func soundcoreLearnsNoiseControlFromItsFirstReport() {
    let driver = SoundcoreDriver(name: "soundcore Liberty 4 NC")
    #expect(driver.capabilities.noiseModes.isEmpty)
    let frame: [UInt8] = [0xFF, 0x09, 0x00, 0x00, 0x01, 0x06, 0x01, 0x0F, 0x00, 0x00, 0x20, 0x00, 0x00, 0x01, 0x00]
    let events = driver.receive(frame).events
    #expect(events.contains(.noiseMode(.cancel, level: .moderate)))
    #expect(events.contains(.toggles([.windNoise: true])))
    #expect(driver.capabilities.noiseModes == [.off, .transparency, .cancel])
    // A change resends every field, plus the Liberty 4 NC's trailer.
    let out = driver.encode(.setNoise(.transparency, level: nil))[0]
    #expect(Array(out.body[9..<(out.body.count - 1)]) == [0x01, 0x20, 0x00, 0x00, 0x01, 0x01, 0x00])
}
