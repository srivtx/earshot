import EarshotCore
import SwiftUI

/// Dims and disables a tab's controls until the buds are linked, without changing layout.
private struct LinkedOnly: ViewModifier {
    @Environment(BudsStore.self) private var store

    func body(content: Content) -> some View {
        content
            .disabled(!store.isLinked)
            .opacity(store.link.needsAction ? 0.4 : 1)
    }
}

// MARK: - Buds

/// Spacers between groups take up spare height evenly, so every tab fills the same frame.
struct BudsTab: View {
    @Environment(BudsStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BudsField()
                .padding(.horizontal, -2)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 10) {
                // The buds only switch modes while a bud is worn, so say so before a tap fails.
                SectionLabel(text: "Noise control",
                             trailing: store.pendingNoiseMode != nil ? "applying…" : (store.noBudWorn ? "wear to switch" : nil))
                SlidingPicker(
                    options: [
                        .init(value: NoiseMode.off, title: "Off", symbol: "circle.slash"),
                        .init(value: NoiseMode.transparency, title: "Ambient", symbol: "wave.3.right"),
                        .init(value: NoiseMode.cancel, title: "ANC", symbol: "shield.lefthalf.filled"),
                    ],
                    selection: store.shownNoiseMode,
                    pending: store.pendingNoiseMode,
                    height: 54
                ) { store.setNoiseMode($0) }
                AncStrength()
            }
            .modifier(LinkedOnly())

            Spacer(minLength: 16)

            FindButton()
                .modifier(LinkedOnly())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// ANC strength as a stepped slider, with Adaptive beside it. Picking either turns ANC on.
private struct AncStrength: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private let levels: [AncLevel] = [.mild, .moderate, .deep]

    var body: some View {
        let active = store.shownNoiseMode == .cancel
        let adaptive = active && store.shownAncLevel == .adaptive

        HStack(alignment: .top, spacing: 14) {
            StepSlider(stops: ["Mild", "Mid", "Deep"],
                       index: active ? store.shownAncLevel.flatMap { levels.firstIndex(of: $0) } : nil) { i in
                store.setAncLevel(levels[i])
            }

            Button {
                store.setAncLevel(.adaptive)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text("ADAPTIVE")
                        .font(Typeface.pixel(8.5, bold: adaptive))
                        .tracking(0.5)
                }
                .foregroundStyle(adaptive ? Ink.ink : (hovering ? palette.text : palette.muted))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    if adaptive {
                        PinkBlock(shadow: 2)
                    } else {
                        Color.clear.surface(raised: hovering)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            .accessibilityLabel("Adaptive noise cancelling")
            .accessibilityAddTraits(adaptive ? .isSelected : [])
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .opacity(active ? 1 : 0.6)
        .animation(.ui, value: active)
        .animation(.knob, value: store.shownAncLevel)
    }
}

// MARK: - Sound

struct SoundTab: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            sections.modifier(LinkedOnly())
        } else {
            ScrollView(.vertical) { sections }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .modifier(LinkedOnly())
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "EQ", trailing: store.pendingEq != nil ? "applying…" : nil)
                EqGrid()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Effects")
                RowGroup {
                    miscRow("Spatial audio", "Wider, surround-like stage", .spatial)
                    SettingRow(title: "Volume boost", caption: "Louder output, with ANC off",
                               isOn: store.volumeBoost) { store.setVolumeBoost($0) }
                    miscRow("Dynamic bass", "Keeps bass full at low volume", .dynamicBass)
                    miscRow("Hi-Res audio", "Phone only. Macs play AAC", .hiRes, tag: "LHDC")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Modes")
                RowGroup {
                    miscRow("Game mode", "Lower latency", .gameMode)
                    miscRow("Dual device", "Phone and Mac at once", .multipoint)
                    miscRow("Wind reduction", "Cuts wind noise", .windNoise)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func miscRow(_ title: String, _ caption: String, _ setting: MiscSetting, tag: String? = nil) -> some View {
        SettingRow(title: title, tag: tag, caption: caption, isOn: store.misc[setting]) { store.setMisc(setting, $0) }
    }
}

/// realme's four presets as printed tiles; the pink block slides to the active one.
private struct EqGrid: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @Namespace private var namespace
    @State private var hovered: EqPreset?

    private let presets: [(EqPreset, String, String)] = [
        (.original, "Original", "flat, as mastered"),
        (.deepBass, "Deep bass", "heavy low end"),
        (.serenade, "Serenade", "warm, vocal-forward"),
        (.clearBass, "Clear bass", "tight, punchy lows"),
    ]

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(presets[0]); tile(presets[1]) }
            GridRow { tile(presets[2]); tile(presets[3]) }
        }
        .animation(.knob, value: store.shownEq)
        .animation(.ui, value: hovered)
    }

    private func tile(_ preset: (EqPreset, String, String)) -> some View {
        let (value, title, caption) = preset
        let selected = store.shownEq == value
        return Button {
            store.setEq(value)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(Typeface.pixel(9, bold: selected))
                        .tracking(0.5)
                    if store.pendingEq == value { Caret(color: Ink.ink) }
                }
                Text(caption)
                    .font(Typeface.mono(9))
                    .opacity(0.75)
            }
            .foregroundStyle(selected ? Ink.ink : (hovered == value ? palette.text : palette.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if selected {
                    PinkBlock().matchedGeometryEffect(id: "eq", in: namespace)
                } else {
                    Color.clear.surface(raised: hovered == value)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 ? value : (hovered == value ? nil : hovered) }
        .accessibilityLabel("EQ \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row with a title, a caption and a switch. Disabled until the buds report the setting.
struct SettingRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var tag: String?
    let caption: String
    let isOn: Bool?
    let set: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typeface.grotesk(13, .medium))
                        .foregroundStyle(palette.text)
                    if let tag { PixelTag(text: tag, style: .ink) }
                }
                Text(caption)
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(palette.faint)
            }
            Spacer()
            PixelSwitch(isOn: Binding(get: { isOn ?? false }, set: set))
                .accessibilityLabel(title)
                .disabled(isOn == nil)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(hovering ? palette.raised : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
    }
}

// MARK: - Taps

struct TapsTab: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var side: BudSide = .left

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlidingPicker(options: [.init(value: BudSide.left, title: "Left bud"), .init(value: BudSide.right, title: "Right bud")],
                          selection: side, height: 30) { side = $0 }

            Spacer(minLength: 14)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Gestures")
                RowGroup {
                    GestureRow(side: side, gesture: .double, title: "Double tap")
                    GestureRow(side: side, gesture: .triple, title: "Triple tap")
                    GestureRow(side: side, gesture: .hold, title: "Touch & hold")
                    GestureRow(side: side, gesture: .single, title: "Single tap")
                }
            }
            .id(side)
            .transition(.opacity)

            Spacer(minLength: 14)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Hold switches between")
                HoldCycle()
            }

            Spacer(minLength: 14)

            Text("Saved on the buds, so taps work the same with your phone.")
                .font(Typeface.mono(9.5))
                .foregroundStyle(palette.faint)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .modifier(LinkedOnly())
        .animation(.ui, value: side)
    }
}

private struct GestureRow: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @Environment(\.isSnapshot) private var isSnapshot
    let side: BudSide
    let gesture: EarshotCore.Gesture
    let title: String
    @State private var hovering = false

    var body: some View {
        let current = store.touch[side]?[gesture]
        HStack(spacing: 10) {
            GestureGlyph(gesture: gesture)
                .frame(width: 22, alignment: .leading)
            Text(title)
                .font(Typeface.grotesk(13, .medium))
            Spacer()
            if isSnapshot {
                menuLabel(current)
            } else {
            Menu {
                ForEach(TouchAction.allCases, id: \.self) { action in
                    Button {
                        store.setTouch(side, gesture, action)
                    } label: {
                        if current == action.rawValue {
                            Label(action.title, systemImage: "checkmark")
                        } else {
                            Text(action.title)
                        }
                    }
                }
            } label: {
                menuLabel(current)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(current == nil)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(hovering ? palette.raised : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
    }

    private func menuLabel(_ current: UInt8?) -> some View {
        HStack(spacing: 6) {
            Text(label(for: current))
                .font(Typeface.mono(11, .medium))
                .foregroundStyle(current == TouchAction.off.rawValue ? palette.faint : palette.accentText)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(palette.faint)
        }
    }

    private func label(for code: UInt8?) -> String {
        guard let code else { return "—" }
        return TouchAction(rawValue: code)?.title ?? "Set in realme Link"
    }
}

/// Pixel shorthand for a gesture: one, two or three taps, or a held bar.
private struct GestureGlyph: View {
    let gesture: EarshotCore.Gesture

    var body: some View {
        HStack(spacing: 2) {
            switch gesture {
            case .hold:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Ink.accent).frame(width: 14, height: 4)
            default:
                ForEach(0..<Int(gesture.rawValue), id: \.self) { _ in
                    SoftPixel(color: Ink.accent, size: 4)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Which modes touch & hold cycles through: pink when included, at least two.
private struct HoldCycle: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            chip(.off, "Off")
            chip(.transparency, "Ambient")
            chip(.cancel, "ANC")
        }
        .animation(.knob, value: store.holdCycle)
    }

    private func chip(_ mode: NoiseMode, _ title: String) -> some View {
        let on = store.holdCycle.contains(mode)
        return Button {
            store.toggleHoldCycle(mode)
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(on ? Ink.ink : .clear)
                    .frame(width: 8, height: 8)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(on ? Ink.ink : palette.faint, lineWidth: 1))
                Text(title.uppercased())
                    .font(Typeface.pixel(9, bold: on))
                    .tracking(0.5)
            }
            .foregroundStyle(on ? Ink.ink : palette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                if on { PinkBlock(shadow: 2) } else { Color.clear.surface() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(title) in hold cycle")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension TouchAction {
    var title: String {
        switch self {
        case .off: "Nothing"
        case .playPause: "Play / pause"
        case .assistant: "Voice assistant"
        case .previous: "Previous track"
        case .next: "Next track"
        case .noiseControl: "Noise control"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .gameMode: "Game mode"
        }
    }
}
