import EarshotCore
import Foundation
import Observation
import ServiceManagement

/// Everything the UI shows, fed by `BudsLink`. Changes are applied optimistically and rolled
/// back if the buds reject them or don't answer.
@MainActor
@Observable
final class BudsStore: BudsLinkDelegate {
    private(set) var link: BudsLink.State = .noBuds
    private(set) var battery: [BatterySlot: BatteryReading] = [:]
    private(set) var placement: [BudSide: BudPlacement] = [:]
    private(set) var noiseMode: NoiseMode?
    private(set) var ancLevel: AncLevel?
    /// The mode we asked for and are waiting to hear back about.
    private(set) var pendingNoiseMode: NoiseMode?
    private(set) var pendingAncLevel: AncLevel?
    private(set) var holdCycle: Set<NoiseMode> = []
    /// Settings the buds reported; ones they don't support never appear.
    private(set) var misc: [MiscSetting: Bool] = [:]
    /// Gesture bindings per bud, as raw action codes so unknown ones are preserved.
    private(set) var touch: [BudSide: [Gesture: UInt8]] = [:]
    private(set) var eq: EqPreset?
    private(set) var pendingEq: EqPreset?
    private(set) var firmware: String?
    private(set) var updatedAt: Date?
    private(set) var volumeBoost: Bool?
    private(set) var ringing = false
    private(set) var notice: Notice?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Why the last change failed, shown briefly under the header. Successes need no message:
    /// the control settling into its new state is the confirmation.
    struct Notice: Equatable {
        var text: String
        var ok: Bool
    }

    @ObservationIgnored private let budsLink = BudsLink()
    /// What the last change was, so its acknowledgement can be confirmed by name.
    @ObservationIgnored private var ringTimer: Timer?
    @ObservationIgnored private var noticeTimer: Timer?

    init() {
        budsLink.delegate = self
        budsLink.start()
    }

    var isLinked: Bool {
        if case .linked = link { return true }
        return false
    }

    /// The lowest earbud level, which is what decides when you need to charge.
    var menuBarLevel: Int? {
        [battery[.left], battery[.right]].compactMap { $0?.level }.min()
    }

    var shownNoiseMode: NoiseMode? { pendingNoiseMode ?? noiseMode }
    var shownAncLevel: AncLevel? { pendingAncLevel ?? ancLevel }
    var shownEq: EqPreset? { pendingEq ?? eq }

    // MARK: - Actions

    func refresh() {
        budsLink.refresh()
        guard isLinked else { return }
        budsLink.send(Request.battery())
        budsLink.send(Request.earbudsStatus())
        budsLink.send(Request.noiseMode())
    }

    func connect() { budsLink.connectAudio() }

    /// Releases the control channel so the next launch can open it immediately.
    func shutdown() { budsLink.shutdown() }

    func setNoiseMode(_ mode: NoiseMode) {
        guard isLinked, mode != shownNoiseMode else { return }
        pendingNoiseMode = mode
        if mode == .cancel, let level = ancLevel {
            // Turn ANC back on at the strength it had.
            pendingAncLevel = level
            budsLink.send(Request.setAncLevel(level))
        } else {
            budsLink.send(Request.setNoiseMode(mode))
        }
    }

    func setAncLevel(_ level: AncLevel) {
        guard isLinked, level != shownAncLevel || shownNoiseMode != .cancel else { return }
        pendingNoiseMode = .cancel
        pendingAncLevel = level
        budsLink.send(Request.setAncLevel(level))
    }

    /// Adds or removes a mode from the hold gesture's cycle; it needs at least two.
    func toggleHoldCycle(_ mode: NoiseMode) {
        guard isLinked else { return }
        var next = holdCycle
        if next.contains(mode) { next.remove(mode) } else { next.insert(mode) }
        guard next.count >= 2 else {
            show("Touch & hold needs at least two modes to switch between.")
            return
        }
        holdCycle = next
        budsLink.send(Request.setHoldCycle(next))
    }

    func setMisc(_ setting: MiscSetting, _ on: Bool) {
        guard isLinked, misc[setting] != nil else { return }
        misc[setting] = on
        budsLink.send(Request.setMisc(setting, on))
        if setting == .spatial { budsLink.send(Request.setSpatialType(on)) }
    }

    func setVolumeBoost(_ on: Bool) {
        guard isLinked, volumeBoost != nil else { return }
        volumeBoost = on
        budsLink.send(Request.setVolumeBoost(on))
    }

    func setEq(_ preset: EqPreset) {
        guard isLinked, preset != shownEq else { return }
        pendingEq = preset
        budsLink.send(Request.setEq(preset))
    }

    func setTouch(_ side: BudSide, _ gesture: Gesture, _ action: TouchAction) {
        guard isLinked, touch[side]?[gesture] != nil else { return }
        touch[side]?[gesture] = action.rawValue
        budsLink.send(Request.setTouch(TouchBinding(side: side, gesture: gesture, action: action.rawValue)))
    }

    func toggleRing() {
        guard isLinked else { return }
        ringing.toggle()
        budsLink.send(Request.findDevice(ringing))
        ringTimer?.invalidate()
        if ringing {
            ringTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.ringing else { return }
                    self.toggleRing()
                }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Couldn't change login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - BudsLinkDelegate

    func linkDidChangeState(_ state: BudsLink.State) {
        link = state
        if case .linked = state { return }
        // Nothing we hold is trustworthy once the channel is gone.
        battery = [:]
        placement = [:]
        noiseMode = nil
        ancLevel = nil
        pendingNoiseMode = nil
        pendingAncLevel = nil
        holdCycle = []
        misc = [:]
        touch = [:]
        eq = nil
        pendingEq = nil
        volumeBoost = nil
        ringing = false
        ringTimer?.invalidate()
    }

    func linkDidReceive(_ event: Event) {
        updatedAt = .now
        switch event {
        case let .battery(readings):
            // A bud missing from the reply is asleep or flat; drop its stale level.
            var next: [BatterySlot: BatteryReading] = [:]
            for reading in readings { next[reading.slot] = reading }
            if next[.chargingCase] == nil, let previous = battery[.chargingCase], previous.charging { next[.chargingCase] = previous }
            battery = next
        case let .placement(map):
            placement = map
        case let .noiseMode(mode, level):
            noiseMode = mode
            if let level { ancLevel = level }
            if pendingNoiseMode == mode { pendingNoiseMode = nil }
            if level != nil, pendingAncLevel == level { pendingAncLevel = nil }
        case let .holdCycle(modes):
            holdCycle = modes
        case let .misc(map):
            misc.merge(map) { _, new in new }
        case let .touch(bindings):
            var next: [BudSide: [Gesture: UInt8]] = [:]
            for binding in bindings { next[binding.side, default: [:]][binding.gesture] = binding.action }
            touch = next
        case let .eq(preset):
            eq = preset
            if pendingEq == preset { pendingEq = nil }
        case let .volumeBoost(on):
            volumeBoost = on
        case let .firmware(version):
            firmware = version
        case let .ack(command, status):
            handleAck(command: command, status: status)
        }
    }

    func linkRequestFailed(_ command: Command) {
        switch command {
        case .ancConfigSet:
            pendingNoiseMode = nil
            pendingAncLevel = nil
            budsLink.send(Request.holdCycle())
            show("The buds didn't answer. Is a bud asleep or out of range?")
        case .miscConfigSet:
            budsLink.send(Request.misc(MiscSetting.allCases))
            show("That setting didn't stick. Try again.")
        case .touchConfigSet:
            budsLink.send(Request.touch())
            show("That tap setting didn't stick. Try again.")
        case .eqSet:
            pendingEq = nil
            budsLink.send(Request.eq())
            show("The buds didn't answer. Try that EQ again.")
        case .volumeBoostSet:
            budsLink.send(Request.volumeBoost())
            show("The buds didn't answer. Try volume boost again.")
        case .findDevice:
            ringing = false
        default:
            break
        }
    }

    /// True when the buds have reported where they are and neither is in an ear.
    var noBudWorn: Bool {
        !placement.isEmpty && !placement.values.contains(.inEar)
    }

    private func handleAck(command: UInt16, status: UInt8) {
        let ok = status == AckStatus.ok
        switch command {
        case Command.volumeBoostSet.rawValue:
            // Read back, so the switch shows what the buds actually hold.
            budsLink.send(Request.volumeBoost())
            if !ok { show("The buds refused volume boost. It may need ANC off.") }
        case Command.ancConfigSet.rawValue:
            if ok {
                if let mode = pendingNoiseMode { noiseMode = mode }
                if let level = pendingAncLevel { ancLevel = level }
            } else {
                budsLink.send(Request.noiseMode())
                budsLink.send(Request.earbudsStatus())
                show(noBudWorn
                     ? "Buds report no bud in an ear. Seat them and retry."
                     : "Buds refused noise control (code \(String(format: "0x%02X", status))).")
            }
            pendingNoiseMode = nil
            pendingAncLevel = nil
        case Command.miscConfigSet.rawValue where !ok:
            budsLink.send(Request.misc(MiscSetting.allCases))
            show("The buds refused that setting.")
        case Command.touchConfigSet.rawValue:
            // Read back either way, so what's shown is what the buds actually hold.
            budsLink.send(Request.touch())
            if !ok { show("The buds refused that tap setting.") }
        case Command.eqSet.rawValue:
            if ok, let preset = pendingEq { eq = preset } else if !ok { show("The buds refused that EQ.") }
            pendingEq = nil
        case Command.findDevice.rawValue where !ok:
            ringing = false
            show("Put a bud in your ear or take it out of the case to ring it.")
        default:
            break
        }
    }

    private func show(_ message: String) {
        post(Notice(text: message, ok: false), for: 4)
    }


    private func post(_ next: Notice, for seconds: TimeInterval) {
        notice = next
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }
}

extension AncLevel {
    var title: String {
        switch self {
        case .adaptive: "adaptive"
        case .deep: "deep"
        case .moderate: "mid"
        case .mild: "mild"
        }
    }
}

extension EqPreset {
    var title: String {
        switch self {
        case .original: "Original sound"
        case .deepBass: "Deep bass"
        case .serenade: "Serenade"
        case .clearBass: "Clear bass"
        }
    }
}

extension MiscSetting {
    var title: String {
        switch self {
        case .gameMode: "Game mode"
        case .multipoint: "Dual device"
        case .hiRes: "Hi-Res audio"
        case .windNoise: "Wind reduction"
        case .spatial: "Spatial audio"
        case .dynamicBass: "Dynamic bass"
        }
    }
}
