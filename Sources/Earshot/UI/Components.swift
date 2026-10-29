import SwiftUI

// MARK: - Labels

/// Printed tag, as on oauth-ready, with softened corners.
struct PixelTag: View {
    enum Style { case pink, hot, ink, ghost }

    let text: String
    var style: Style = .pink

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.tag, style: .continuous)
        Text(text.uppercased())
            .font(Typeface.pixel(9))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .overlay { if style == .ghost { shape.strokeBorder(Ink.ink.opacity(0.35), lineWidth: 1) } }
    }

    private var foreground: Color {
        switch style {
        case .pink, .hot: Ink.ink
        case .ink: Ink.accent
        case .ghost: Ink.ink.opacity(0.6)
        }
    }

    private var background: Color {
        switch style {
        case .pink: Ink.accent
        case .hot: Ink.hot
        case .ink: Ink.ink
        case .ghost: .clear
        }
    }
}

/// Small uppercase section label with a soft pink pixel bullet.
struct SectionLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            SoftPixel(color: Ink.accent, size: 5)
            Text(text.uppercased())
                .font(Typeface.pixel(9))
                .tracking(0.6)
                .foregroundStyle(palette.muted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Typeface.mono(10))
                    .foregroundStyle(palette.faint)
                    .transition(.opacity)
            }
        }
    }
}

/// One soft pixel: a block with rounded corners, morphotype's "Soft pixel" look.
struct SoftPixel: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Ten soft-pixel level blocks that fill one after another.
struct PixelMeter: View {
    let level: Int?
    var segments = 10
    var block: CGFloat = 6
    var on: Color = Ink.ink
    var off: Color = Ink.ink.opacity(0.16)

    var body: some View {
        let filled = level.map { $0 <= 0 ? 0 : max(1, Int((Double($0) / 100 * Double(segments)).rounded(.up))) } ?? 0
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                SoftPixel(color: index < filled ? on : off, size: block)
                    .animation(.ui.delay(Double(index) * 0.02), value: filled)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Blinking soft-pixel caret.
struct Caret: View {
    var color: Color = Ink.accent
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 6, height: 10)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.01).delay(0.5).repeatForever(autoreverses: true)) { visible = false }
            }
    }
}

// MARK: - Pink selection

/// The selected state everywhere: a rounded pink block, ink hairline, and a printed offset shadow.
struct PinkBlock: View {
    var radius: CGFloat = Radius.control
    var shadow: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Ink.accent)
            .overlay(shape.strokeBorder(Ink.ink, lineWidth: 1))
            .background(shape.fill(Color.black.opacity(0.8)).offset(x: shadow, y: shadow))
    }
}

/// A row of options on a rounded track, with the pink block sliding to the selected one.
struct SlidingPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
    }

    @Environment(\.palette) private var palette
    let options: [Option]
    let selection: Value?
    var pending: Value?
    var height: CGFloat = 28
    let onSelect: (Value) -> Void

    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    VStack(spacing: 6) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .symbolEffect(.pulse, isActive: pending == option.value)
                        }
                        Text(option.title.uppercased())
                            .font(Typeface.pixel(9, bold: selected))
                            .tracking(0.5)
                    }
                    .foregroundStyle(selected ? Ink.ink : (hovered == option.value ? palette.text : palette.muted))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        if selected {
                            PinkBlock(radius: Radius.control - 2, shadow: 2)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        } else if hovered == option.value {
                            RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous).fill(palette.raised)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .surface(radius: Radius.control + 2)
        .animation(.knob, value: selection)
        .animation(.ui, value: hovered)
    }
}

/// Buttons sink slightly when pressed, like a printed key.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Chunky printed button: rounded, ink hairline, and an offset shadow that collapses on press.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color?
    var foreground: Color?

    func makeBody(configuration: Configuration) -> some View {
        ChunkyBody(configuration: configuration, fill: fill, foreground: foreground)
    }

    private struct ChunkyBody: View {
        @Environment(\.palette) private var palette
        @State private var hovering = false
        let configuration: Configuration
        let fill: Color?
        let foreground: Color?

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            configuration.label
                .font(Typeface.pixel(10, bold: true))
                .tracking(0.6)
                .foregroundStyle(foreground ?? palette.text)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background {
                    if let fill {
                        shape.fill(fill).overlay(shape.strokeBorder(Ink.ink, lineWidth: 1))
                    } else {
                        shape.fill(.clear).surface(raised: hovering)
                    }
                }
                .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
                .background(shape.fill(Color.black.opacity(fill == nil ? 0.3 : 0.8)).offset(x: 3, y: 3))
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: pressed)
                .animation(.ui, value: hovering)
        }
    }
}

// MARK: - Switch

/// Soft block switch: the rounded knob springs across a rounded track.
struct PixelSwitch: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Binding var isOn: Bool

    var body: some View {
        let track = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                track
                    .fill(isOn ? Ink.accent : palette.raised)
                    .overlay(track.strokeBorder(isOn ? Ink.ink : palette.line, lineWidth: 1))
                SoftPixel(color: isOn ? Ink.ink : palette.muted, size: 12)
                    .padding(3)
            }
            .frame(width: 38, height: 18)
            .opacity(enabled ? 1 : 0.4)
            .animation(.knob, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Step slider

/// A slider that snaps to labelled stops, with soft-pixel stops and a rounded thumb.
struct StepSlider: View {
    @Environment(\.palette) private var palette
    let stops: [String]
    /// nil when no stop applies (the thumb hides).
    let index: Int?
    let onChange: (Int) -> Void

    @State private var dragX: CGFloat?

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let inset: CGFloat = 8
                let width = geo.size.width - inset * 2
                let step = width / CGFloat(max(stops.count - 1, 1))
                let showing = index != nil || dragX != nil
                let thumbX = dragX ?? (index.map { CGFloat($0) * step } ?? 0)

                ZStack(alignment: .leading) {
                    Capsule().fill(palette.line).frame(height: 3)
                    if showing {
                        Capsule().fill(Ink.accent).frame(width: thumbX, height: 3)
                    }
                    ForEach(stops.indices, id: \.self) { i in
                        SoftPixel(color: showing && CGFloat(i) * step <= thumbX ? Ink.accent : palette.line, size: 7)
                            .offset(x: CGFloat(i) * step - 3.5)
                    }
                    if showing {
                        let thumb = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        thumb
                            .fill(Ink.accent)
                            .overlay(thumb.strokeBorder(Ink.ink, lineWidth: 1))
                            .background(thumb.fill(Color.black.opacity(0.8)).offset(x: 2, y: 2))
                            .frame(width: 15, height: 15)
                            .scaleEffect(dragX != nil ? 1.15 : 1)
                            .offset(x: thumbX - 7.5)
                    }
                }
                .padding(.horizontal, inset)
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragX = min(max(value.location.x - inset, 0), width)
                        }
                        .onEnded { value in
                            let x = min(max(value.location.x - inset, 0), width)
                            let target = Int((x / step).rounded())
                            withAnimation(.knob) { dragX = nil }
                            onChange(target)
                        }
                )
                .animation(.knob, value: index)
            }
            .frame(height: 18)

            HStack {
                ForEach(stops.indices, id: \.self) { i in
                    Text(stops[i].uppercased())
                        .font(Typeface.pixel(8.5, bold: i == index))
                        .tracking(0.5)
                        .foregroundStyle(i == index ? palette.text : palette.faint)
                        .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : (i == stops.count - 1 ? .trailing : .center))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Strength")
        .accessibilityValue(index.map { stops[$0] } ?? "Off")
        .accessibilityAdjustableAction { direction in
            let current = index ?? 0
            switch direction {
            case .increment: onChange(min(current + 1, stops.count - 1))
            case .decrement: onChange(max(current - 1, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Grouped rows

/// Rows stacked in one rounded panel with inset hairlines, like a System Settings group.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                    if index < rows.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .surface(radius: Radius.group)
    }
}

private struct RowDivider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 12)
    }
}

