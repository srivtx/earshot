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

/// Stands in for a section the connected model doesn't have.
private struct NotHere: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    let what: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PixelSprite(rows: Sprites.mark, palette: Sprites.markPalette, pixel: 4)
            Text("\(what) for these buds aren't in Earshot yet.")
                .font(Typeface.grotesk(13, .medium))
                .foregroundStyle(palette.text)
            Text("Change them in \(store.companionApp). Saved on the buds, they stay as you set them.")
                .font(Typeface.mono(9.5))
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Radius.group)
    }
}

// MARK: - Buds

/// Spacers between groups take up spare height evenly, so every tab fills the same frame.
struct BudsTab: View {
    @Environment(BudsStore.self) private var store

    var body: some View {
        let caps = store.caps
        VStack(alignment: .leading, spacing: 0) {
            BudsField()
                .padding(.horizontal, -2)

            Spacer(minLength: 16)

            if !caps.noiseModes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    // Some buds only switch modes while a bud is worn, so say so before a tap fails.
                    SectionLabel(text: "Noise control",
                                 trailing: store.pendingNoiseMode != nil ? "applying…"
                                     : (caps.noiseNeedsWear && store.noBudWorn ? "wear to switch" : nil))
                    SlidingPicker(
                        options: caps.noiseModes.map { mode in
                            switch mode {
                            case .off: .init(value: mode, title: "Off", symbol: "circle.slash")
                            case .transparency: .init(value: mode, title: "Ambient", symbol: "wave.3.right")
                            case .cancel: .init(value: mode, title: "ANC", symbol: "shield.lefthalf.filled")
                            }
                        },
                        selection: store.shownNoiseMode,
                        pending: store.pendingNoiseMode,
                        height: 54
                    ) { store.setNoiseMode($0) }
                    if caps.noiseModes.contains(.cancel), !caps.ancLevels.isEmpty || caps.adaptiveAnc {
                        AncStrength(levels: caps.ancLevels, adaptive: caps.adaptiveAnc)
                    }
                }
                .modifier(LinkedOnly())

                Spacer(minLength: 16)
            }

            if caps.find {
                FindButton()
                    .modifier(LinkedOnly())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// ANC strength as a stepped slider, with Adaptive beside it. Picking either turns ANC on.
private struct AncStrength: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    let levels: [AncLevel]
    let adaptive: Bool
    @State private var hovering = false

    var body: some View {
        let active = store.shownNoiseMode == .cancel
        let isAdaptive = active && store.shownAncLevel == .adaptive

        HStack(alignment: .top, spacing: 14) {
            if !levels.isEmpty {
                StepSlider(stops: levels.map { $0.title.capitalized },
                           index: active ? store.shownAncLevel.flatMap { levels.firstIndex(of: $0) } : nil) { i in
                    store.setAncLevel(levels[i])
                }
            } else {
                Text("Strength")
                    .font(Typeface.mono(10))
                    .foregroundStyle(palette.faint)
                Spacer()
            }

            if adaptive {
                Button {
                    store.setAncLevel(.adaptive)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("ADAPTIVE")
                            .font(Typeface.pixel(8.5, bold: isAdaptive))
                            .tracking(0.5)
                    }
                    .foregroundStyle(isAdaptive ? Ink.ink : (hovering ? palette.text : palette.muted))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background {
                        if isAdaptive {
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
                .accessibilityAddTraits(isAdaptive ? .isSelected : [])
            }
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

    private static let effects: [EarshotCore.Toggle] = [.spatial, .volumeBoost, .dynamicBass, .ultraBass, .hiRes]
    private static let modes: [EarshotCore.Toggle] = [.gameMode, .multipoint, .windNoise]

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

    /// Toggles the buds reported, plus ones the model is known to have.
    private func shown(_ group: [EarshotCore.Toggle]) -> [EarshotCore.Toggle] {
        group.filter { store.toggles[$0] != nil || store.caps.toggles.contains($0) }
    }

    private var sections: some View {
        let presets = store.caps.eqPresets
        let effects = shown(Self.effects)
        let modes = shown(Self.modes)
        return VStack(alignment: .leading, spacing: 16) {
            if !presets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "EQ", trailing: store.pendingEq != nil ? "applying…" : nil)
                    EqGrid(presets: presets)
                }
            }
            if !effects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Effects")
                    RowGroup {
                        ForEach(effects, id: \.self) { row($0) }
                    }
                }
            }
            if !modes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Modes")
                    RowGroup {
                        ForEach(modes, id: \.self) { row($0) }
                    }
                }
            }
            if presets.isEmpty, effects.isEmpty, modes.isEmpty {
                NotHere(what: "Sound settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func row(_ toggle: EarshotCore.Toggle) -> some View {
        SettingRow(title: toggle.title, tag: toggle.tag(for: store.profile?.brand), caption: toggle.caption,
                   isOn: store.toggles[toggle]) { store.setToggle(toggle, $0) }
    }
}

extension EarshotCore.Toggle {
    var title: String {
        switch self {
        case .spatial: "Spatial audio"
        case .volumeBoost: "Volume boost"
        case .dynamicBass: "Dynamic bass"
        case .ultraBass: "Ultra bass"
        case .hiRes: "Hi-Res audio"
        case .gameMode: "Game mode"
        case .multipoint: "Dual device"
        case .windNoise: "Wind reduction"
        }
    }

    var caption: String {
        switch self {
        case .spatial: "Wider, surround-like stage"
        case .volumeBoost: "Louder output, with ANC off"
        case .dynamicBass: "Keeps bass full at low volume"
        case .ultraBass: "Extra low end"
        case .hiRes: "Phone only. Macs play AAC"
        case .gameMode: "Lower latency"
        case .multipoint: "Phone and Mac at once"
        case .windNoise: "Cuts wind noise"
        }
    }

    func tag(for brand: Brand?) -> String? {
        switch (self, brand) {
        case (.hiRes, .realme?), (.hiRes, .oppo?), (.hiRes, .oneplus?), (.hiRes, nil): "LHDC"
        default: nil
        }
    }
}

/// The model's EQ presets as printed tiles, two to a row; the pink block slides to the active one.
private struct EqGrid: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    let presets: [EqPreset]
    @Namespace private var namespace
    @State private var hovered: UInt8?

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: presets.count, by: 2)), id: \.self) { i in
                GridRow {
                    tile(presets[i])
                    if i + 1 < presets.count {
                        tile(presets[i + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .animation(.knob, value: store.shownEq)
        .animation(.ui, value: hovered)
    }

    private func tile(_ preset: EqPreset) -> some View {
        let selected = store.shownEq == preset.id
        return Button {
            store.setEq(preset.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.title.uppercased())
                        .font(Typeface.pixel(9, bold: selected))
                        .tracking(0.5)
                        .lineLimit(1)
                    if store.pendingEq == preset.id { Caret(color: Ink.ink) }
                }
                Text(preset.caption)
                    .font(Typeface.mono(9))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Ink.ink : (hovered == preset.id ? palette.text : palette.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if selected {
                    PinkBlock().matchedGeometryEffect(id: "eq", in: namespace)
                } else {
                    Color.clear.surface(raised: hovered == preset.id)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 ? preset.id : (hovered == preset.id ? nil : hovered) }
        .accessibilityLabel("EQ \(preset.title)")
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
        let caps = store.caps
        VStack(alignment: .leading, spacing: 0) {
            if caps.gestures.isEmpty {
                NotHere(what: "Tap controls")
                Spacer(minLength: 0)
            } else {
                SlidingPicker(options: [.init(value: BudSide.left, title: "Left bud"), .init(value: BudSide.right, title: "Right bud")],
                              selection: side, height: 30) { side = $0 }

                Spacer(minLength: 14)

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Gestures")
                    RowGroup {
                        ForEach(caps.gestures, id: \.self) { gesture in
                            GestureRow(side: side, gesture: gesture, actions: caps.touchActions)
                        }
                    }
                }
                .id(side)
                .transition(.opacity)

                if !caps.holdCycle.isEmpty {
                    Spacer(minLength: 14)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Hold switches between")
                        HoldCycle(modes: caps.holdCycle)
                    }
                }

                Spacer(minLength: 14)

                Text("Saved on the buds, so taps work the same with your phone.")
                    .font(Typeface.mono(9.5))
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .modifier(LinkedOnly())
        .animation(.ui, value: side)
    }
}

extension EarshotCore.Gesture {
    var title: String {
        switch self {
        case .single: "Single tap"
        case .double: "Double tap"
        case .triple: "Triple tap"
        case .hold: "Touch & hold"
        }
    }

    var taps: Int {
        switch self {
        case .single: 1
        case .double: 2
        case .triple: 3
        case .hold: 0
        }
    }
}

private struct GestureRow: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @Environment(\.isSnapshot) private var isSnapshot
    let side: BudSide
    let gesture: EarshotCore.Gesture
    let actions: [TouchAction]
    @State private var hovering = false

    var body: some View {
        let current = store.touch[side]?[gesture]
        HStack(spacing: 10) {
            GestureGlyph(gesture: gesture)
                .frame(width: 22, alignment: .leading)
            Text(gesture.title)
                .font(Typeface.grotesk(13, .medium))
            Spacer()
            if isSnapshot {
                menuLabel(current)
            } else {
                Menu {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            store.setTouch(side, gesture, action)
                        } label: {
                            if current == action {
                                Label(action.title ?? "", systemImage: "checkmark")
                            } else {
                                Text(action.title ?? "")
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

    private func menuLabel(_ current: TouchAction?) -> some View {
        HStack(spacing: 6) {
            Text(label(for: current))
                .font(Typeface.mono(11, .medium))
                .foregroundStyle(current == .off ? palette.faint : palette.accentText)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(palette.faint)
        }
    }

    private func label(for action: TouchAction?) -> String {
        guard let action else { return "—" }
        return action.title ?? "Set in \(store.companionApp)"
    }
}

/// Pixel shorthand for a gesture: one, two or three taps, or a held bar.
private struct GestureGlyph: View {
    let gesture: EarshotCore.Gesture

    var body: some View {
        HStack(spacing: 2) {
            if gesture == .hold {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Ink.accent).frame(width: 14, height: 4)
            } else {
                ForEach(0..<gesture.taps, id: \.self) { _ in
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
    let modes: [NoiseMode]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes, id: \.self) { chip($0) }
        }
        .animation(.knob, value: store.holdCycle)
    }

    private func chip(_ mode: NoiseMode) -> some View {
        let on = store.holdCycle.contains(mode)
        let title = switch mode {
        case .off: "Off"
        case .transparency: "Ambient"
        case .cancel: "ANC"
        }
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
    /// Nil for codes Earshot doesn't know.
    var title: String? {
        switch self {
        case .off: "Nothing"
        case .playPause: "Play / pause"
        case .assistant: "Voice assistant"
        case .previous: "Previous track"
        case .next: "Next track"
        case .noiseControl: "Noise control"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .volume: "Volume"
        case .gameMode: "Game mode"
        case .spotify: "Spotify"
        case .other: nil
        }
    }
}
