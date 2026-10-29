import AppKit
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
    /// What the connected model can do; nil until linked.
    private(set) var capabilities: Capabilities?
    /// The paired model's controls before it links, so the layout doesn't jump when it does.
    private(set) var preview: Capabilities?
    private(set) var battery: [BatterySlot: BatteryReading] = [:]
    private(set) var placement: [BudSide: BudPlacement] = [:]
    private(set) var noiseMode: NoiseMode?
    private(set) var ancLevel: AncLevel?
    /// The mode we asked for and are waiting to hear back about.
    private(set) var pendingNoiseMode: NoiseMode?
    private(set) var pendingAncLevel: AncLevel?
    private(set) var holdCycle: Set<NoiseMode> = []
    /// Settings the buds reported; ones they don't support never appear.
    private(set) var toggles: [Toggle: Bool] = [:]
    private(set) var touch: [BudSide: [Gesture: TouchAction]] = [:]
    private(set) var eq: UInt8?
    private(set) var pendingEq: UInt8?
    private(set) var firmware: String?
    private(set) var updatedAt: Date?
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

    var profile: Profile? { budsLink.profile }

    /// The lowest earbud level, which is what decides when you need to charge.
    var menuBarLevel: Int? {
        if let single = battery[.single] { return single.level }
        return [battery[.left], battery[.right]].compactMap { $0?.level }.min()
    }

    var shownNoiseMode: NoiseMode? { pendingNoiseMode ?? noiseMode }
    var shownAncLevel: AncLevel? { pendingAncLevel ?? ancLevel }
    var shownEq: UInt8? { pendingEq ?? eq }

    /// What to lay out: the linked model, else the paired one, else the realme Buds Air 7.
    var caps: Capabilities { capabilities ?? preview ?? Self.placeholder }
    private static let placeholder = OPODriver(companionApp: "realme Link", knownToggles: Profiles.airSevenToggles).capabilities

    var companionApp: String { caps.companionApp }

    /// The paired buds have only been built from published protocol work, not tried on hardware.
    var isExperimental: Bool { profile.map { !$0.tested } ?? false }

    // MARK: - Actions

    func refresh() {
        budsLink.refresh()
        budsLink.send(.refresh)
    }

    func connect() { budsLink.connectAudio() }

    /// Releases the control channel so the next launch can open it immediately.
    func shutdown() { budsLink.shutdown() }

    func setNoiseMode(_ mode: NoiseMode) {
        guard isLinked, mode != shownNoiseMode else { return }
        pendingNoiseMode = mode
        // Turn ANC back on at the strength it had.
        if mode == .cancel, let level = ancLevel { pendingAncLevel = level }
        budsLink.send(.setNoise(mode, level: mode == .cancel ? ancLevel : nil))
    }

    func setAncLevel(_ level: AncLevel) {
        guard isLinked, level != shownAncLevel || shownNoiseMode != .cancel else { return }
        pendingNoiseMode = .cancel
        pendingAncLevel = level
        budsLink.send(.setNoise(.cancel, level: level))
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
        budsLink.send(.setHoldCycle(next))
    }

    func setToggle(_ toggle: Toggle, _ on: Bool) {
        guard isLinked, toggles[toggle] != nil else { return }
        toggles[toggle] = on
        budsLink.send(.setToggle(toggle, on))
    }

    func setEq(_ preset: UInt8) {
        guard isLinked, preset != shownEq else { return }
        pendingEq = preset
        budsLink.send(.setEq(preset))
    }

    func setTouch(_ side: BudSide, _ gesture: Gesture, _ action: TouchAction) {
        guard isLinked, touch[side]?[gesture] != nil else { return }
        touch[side]?[gesture] = action
        budsLink.send(.setTouch(TouchBinding(side: side, gesture: gesture, action: action)))
    }

    func toggleRing() {
        guard isLinked else { return }
        ringing.toggle()
        budsLink.send(.find(ringing))
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

    /// Writes what the buds said recently to a text file in Downloads and shows it in Finder.
    func saveReport() {
        let journal = budsLink.journal
        guard !journal.isEmpty else {
            show("Connect your buds first, so there's something to report.")
            return
        }
        let text = journal.report(firmware: firmware, capabilities: capabilities)
        let name = (link.name ?? "buds").replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = folder.appendingPathComponent("Earshot report – \(name).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            show("Couldn't save the report: \(error.localizedDescription)")
        }
    }

    // MARK: - BudsLinkDelegate

    func linkDidChangeState(_ state: BudsLink.State) {
        link = state
        preview = budsLink.profile.map { $0.driver(name: state.name ?? "").capabilities }
        if case .linked = state { return }
        // Nothing we hold is trustworthy once the channel is gone.
        capabilities = nil
        battery = [:]
        placement = [:]
        noiseMode = nil
        ancLevel = nil
        pendingNoiseMode = nil
        pendingAncLevel = nil
        holdCycle = []
        toggles = [:]
        touch = [:]
        eq = nil
        pendingEq = nil
        firmware = nil
        ringing = false
        ringTimer?.invalidate()
    }

    func linkDidOpen(_ capabilities: Capabilities) {
        self.capabilities = capabilities
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
            if mode == .cancel, level == nil, pendingNoiseMode == nil { pendingAncLevel = nil }
        case let .holdCycle(modes):
            holdCycle = modes
        case let .toggles(map):
            toggles.merge(map) { _, new in new }
        case let .touch(bindings):
            var next = touch
            for binding in bindings { next[binding.side, default: [:]][binding.gesture] = binding.action }
            touch = next
        case let .eq(preset):
            eq = preset
            if pendingEq == preset { pendingEq = nil }
        case let .firmware(version):
            firmware = version
        case .capabilities:
            break
        case let .applied(setting):
            applied(setting)
        case let .refused(setting, code):
            refused(setting, code: code)
        }
    }

    func linkRequestFailed(_ setting: Setting) {
        switch setting {
        case .noise:
            pendingNoiseMode = nil
            pendingAncLevel = nil
            show("The buds didn't answer. Is a bud asleep or out of range?")
        case .holdCycle:
            show("That setting didn't stick. Try again.")
        case .toggle:
            show("That setting didn't stick. Try again.")
        case .touch:
            show("That tap setting didn't stick. Try again.")
        case .eq:
            pendingEq = nil
            show("The buds didn't answer. Try that EQ again.")
        case .find:
            ringing = false
        }
        budsLink.send(.read(setting))
    }

    /// True when the buds have reported where they are and neither is in an ear.
    var noBudWorn: Bool {
        !placement.isEmpty && !placement.values.contains(.inEar)
    }

    private func applied(_ setting: Setting) {
        switch setting {
        case .noise:
            if let mode = pendingNoiseMode { noiseMode = mode }
            if let level = pendingAncLevel { ancLevel = level }
            pendingNoiseMode = nil
            pendingAncLevel = nil
        case .eq:
            if let preset = pendingEq { eq = preset }
            pendingEq = nil
        case .holdCycle, .toggle, .touch, .find:
            break
        }
    }

    private func refused(_ setting: Setting, code: UInt8) {
        switch setting {
        case .noise:
            pendingNoiseMode = nil
            pendingAncLevel = nil
            show(capabilities?.noiseNeedsWear == true && (noBudWorn || code == OPOAck.notWorn)
                 ? "Buds report no bud in an ear. Seat them and retry."
                 : "Buds refused noise control (code \(String(format: "0x%02X", code))).")
        case .toggle(.volumeBoost):
            show("The buds refused volume boost. It may need ANC off.")
        case .toggle, .holdCycle:
            show("The buds refused that setting.")
        case .touch:
            show("The buds refused that tap setting.")
        case .eq:
            pendingEq = nil
            show("The buds refused that EQ.")
        case .find:
            ringing = false
            show("Put a bud in your ear or take it out of the case to ring it.")
        }
    }

    private func show(_ message: String) {
        notice = Notice(text: message, ok: false)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
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
