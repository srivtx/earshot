// What earbuds report and what Earshot can ask of them, in brand-neutral terms.
// Each driver translates between this model and its brand's wire protocol.

public enum BatterySlot: Sendable, CaseIterable {
    case left, right, chargingCase
    /// Headphones with one battery.
    case single
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

public enum BudSide: Sendable, CaseIterable {
    case left, right
}

public enum BudPlacement: Equatable, Sendable {
    case inCase, outOfEar, inEar, unknown
}

public enum NoiseMode: Sendable, CaseIterable {
    case off, transparency, cancel
}

/// ANC strength. `adaptive` lets the buds pick it from the surroundings.
public enum AncLevel: Sendable, CaseIterable {
    case mild, moderate, deep, adaptive
}

/// On/off settings. Rows appear only for the ones the buds report.
public enum Toggle: Sendable, CaseIterable {
    case spatial, volumeBoost, dynamicBass, ultraBass, hiRes
    case gameMode, multipoint, windNoise
}

public struct EqPreset: Equatable, Hashable, Sendable {
    /// The brand's own preset code.
    public var id: UInt8
    public var title: String
    public var caption: String

    public init(_ id: UInt8, _ title: String, _ caption: String) {
        self.id = id
        self.title = title
        self.caption = caption
    }
}

public enum Gesture: Sendable, CaseIterable {
    case single, double, triple, hold
}

public enum TouchAction: Hashable, Sendable {
    case off, playPause, assistant, previous, next, noiseControl
    case volumeUp, volumeDown
    /// One gesture for both: down on the left bud, up on the right.
    case volume
    case gameMode, spotify
    /// A code Earshot doesn't know, kept so it survives a round trip.
    case other(UInt8)
}

public struct TouchBinding: Equatable, Sendable {
    public var side: BudSide
    public var gesture: Gesture
    public var action: TouchAction

    public init(side: BudSide, gesture: Gesture, action: TouchAction) {
        self.side = side
        self.gesture = gesture
        self.action = action
    }
}

/// What a model can do, so the UI shows only controls that work.
public struct Capabilities: Equatable, Sendable {
    public enum Kind: Sendable { case earbuds, headphones }

    public var kind: Kind = .earbuds
    public var noiseModes: [NoiseMode] = []
    /// Stepped ANC strengths, mildest first.
    public var ancLevels: [AncLevel] = []
    public var adaptiveAnc = false
    /// The buds refuse noise changes unless a bud is in an ear.
    public var noiseNeedsWear = false
    /// Modes the hold gesture can be set to cycle through; empty when it can't be configured.
    public var holdCycle: [NoiseMode] = []
    public var eqPresets: [EqPreset] = []
    /// Settings the model is known to have, shown dimmed until the buds report them. Others appear
    /// once reported.
    public var toggles: [Toggle] = []
    public var gestures: [Gesture] = []
    public var touchActions: [TouchAction] = []
    public var find = false
    /// Where to change what Earshot can't, e.g. "realme Link".
    public var companionApp: String

    public init(companionApp: String) {
        self.companionApp = companionApp
    }
}

/// A group of settings, used to report results.
public enum Setting: Hashable, Sendable {
    case noise, holdCycle, toggle(Toggle), eq, touch, find
}

public enum Intent: Equatable, Sendable {
    /// `level` picks the ANC strength; nil keeps the current one.
    case setNoise(NoiseMode, level: AncLevel?)
    case setHoldCycle(Set<NoiseMode>)
    case setToggle(Toggle, Bool)
    case setEq(UInt8)
    case setTouch(TouchBinding)
    case find(Bool)
    /// Battery and wear state.
    case refresh
    /// Re-read a setting, e.g. after a change failed.
    case read(Setting)
}

public enum Event: Equatable, Sendable {
    /// Every slot the buds report; a missing bud is asleep or flat.
    case battery([BatteryReading])
    case placement([BudSide: BudPlacement])
    /// `level` is set when ANC is on and its strength is known.
    case noiseMode(NoiseMode, level: AncLevel?)
    case holdCycle(Set<NoiseMode>)
    case toggles([Toggle: Bool])
    case touch([TouchBinding])
    case eq(UInt8)
    case firmware(String)
    /// The driver learned more about the model, e.g. from its first reply.
    case capabilities(Capabilities)
    case applied(Setting)
    case refused(Setting, code: UInt8)
}
