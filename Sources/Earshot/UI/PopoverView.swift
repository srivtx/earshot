import AppKit
import EarshotCore
import SwiftUI

enum Tab: String, CaseIterable {
    case buds, sound, taps
}

struct PopoverView: View {
    @Environment(BudsStore.self) private var store
    @AppStorage("tab") private var tab: Tab = .buds
    @AppStorage("theme") private var theme: Theme = .system
    /// The Mac's own appearance, read before this view overrides the colour scheme below.
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingSettings = false

    var body: some View {
        let palette = Palette.of(theme, systemIsDark: systemScheme == .dark)

        VStack(alignment: .leading, spacing: 0) {
            Header(showingSettings: $showingSettings)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            // Content swaps inside one fixed frame, so the menu-bar window never resizes (which makes it jump).
            ZStack(alignment: .top) {
                if showingSettings {
                    SettingsView(theme: $theme)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
                            .combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        SlidingPicker(options: Tab.allCases.map { .init(value: $0, title: $0.rawValue) },
                                      selection: tab, height: 26) { tab = $0 }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)

                        Group {
                            switch tab {
                            case .buds: BudsTab()
                            case .sound: SoundTab()
                            case .taps: TapsTab()
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .id(tab)
                        .transition(.opacity)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
                        .combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        // Pinned to the top: if anything ever runs long it's clipped at the bottom, never the header.
        .frame(width: 348, height: 600, alignment: .top)
        .clipped()
        .background(WindowBackground())
        .background { Shortcuts(showingSettings: $showingSettings) }
        .foregroundStyle(palette.text)
        .environment(\.palette, palette)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .animation(.ui, value: showingSettings)
        .animation(.ui, value: tab)
        .animation(.ui, value: theme)
        .animation(.ui, value: store.notice)
    }
}

/// Keyboard shortcuts that work while the popover is open.
private struct Shortcuts: View {
    @Environment(BudsStore.self) private var store
    @Binding var showingSettings: Bool

    var body: some View {
        ZStack {
            Button("") { store.refresh() }.keyboardShortcut("r")
            Button("") { showingSettings.toggle() }.keyboardShortcut(",")
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct Header: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @Binding var showingSettings: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PixelSprite(rows: Sprites.mark, palette: Sprites.markPalette, pixel: 4)
                    (Text("EAR").foregroundStyle(palette.text) + Text("SHOT").foregroundStyle(Ink.accent))
                        .font(Typeface.pixel(14, bold: true))
                        .tracking(1)
                }
                // Doubles as the one place an error appears, briefly, instead of a toast.
                Text(store.notice?.text ?? subtitle)
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(store.notice == nil ? palette.faint : Ink.hot)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(.ui, value: store.notice)
            }

            Spacer()

            LinkStatus(state: store.link)

            Button {
                showingSettings.toggle()
            } label: {
                // A soft-pixel gear that turns a notch on hover and a quarter turn when open.
                PixelSprite(rows: Sprites.gear,
                            palette: ["#": showingSettings ? Ink.ink : (hovering ? palette.text : palette.muted)],
                            pixel: 2.2)
                    .rotationEffect(.degrees(showingSettings ? 90 : (hovering ? 30 : 0)))
                    .frame(width: 30, height: 30)
                    .background {
                        if showingSettings {
                            PinkBlock(shadow: 2)
                        } else {
                            Color.clear.surface(raised: hovering)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .animation(.knob, value: hovering)
                    .animation(.knob, value: showingSettings)
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            .help("Settings (⌘,)")
            .accessibilityLabel(showingSettings ? "Close settings" : "Settings")
        }
    }

    private var subtitle: String {
        let name = store.link.name ?? "no realme buds paired"
        if let firmware = store.firmware { return "\(name) · fw \(firmware)" }
        return name
    }
}

/// Quiet status text, only when the link needs attention. A working link needs no badge.
private struct LinkStatus: View {
    @Environment(\.palette) private var palette
    let state: BudsLink.State

    var body: some View {
        switch state {
        case .linked:
            EmptyView()
        case .linking:
            HStack(spacing: 5) {
                Text("linking").foregroundStyle(Ink.accent)
                Caret()
            }
            .font(Typeface.mono(10.5))
        case .away:
            Text("away").font(Typeface.mono(10.5)).foregroundStyle(palette.muted)
        case .noBuds:
            Text("not paired").font(Typeface.mono(10.5)).foregroundStyle(palette.muted)
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette
    @Binding var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Theme")
                ThemePicker(theme: $theme)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "General")
                RowGroup {
                SettingRow(title: "Launch at login", caption: "Start Earshot when you log in",
                           isOn: store.launchAtLogin) { store.setLaunchAtLogin($0) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reconnect")
                            .font(Typeface.grotesk(13, .medium))
                        Text("Reopen the control channel (⌘R)")
                            .font(Typeface.mono(9.5))
                            .foregroundStyle(palette.faint)
                    }
                    Spacer()
                    Button("Refresh") { store.refresh() }
                        .buttonStyle(ChunkyButtonStyle())
                        .fixedSize()
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "About")
                VStack(alignment: .leading, spacing: 4) {
                    aboutLine("Buds", store.link.name ?? "—")
                    aboutLine("Firmware", store.firmware ?? "—")
                    aboutLine("Earshot", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(radius: Radius.group)
            }

            Spacer(minLength: 0)

            Button("Quit Earshot") { NSApp.terminate(nil) }
                .buttonStyle(ChunkyButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func aboutLine(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(palette.faint)
            Spacer()
            Text(value).foregroundStyle(palette.text)
        }
        .font(Typeface.mono(10.5))
    }
}

/// Three swatch cards, each a tiny preview of the popover in that theme.
private struct ThemePicker: View {
    @Binding var theme: Theme
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Theme.allCases) { option in
                let selected = option == theme
                Button {
                    theme = option
                } label: {
                    VStack(spacing: 8) {
                        ThemeSwatch(theme: option)
                            .frame(height: 62)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                        .strokeBorder(Ink.accent, lineWidth: 2)
                                        .matchedGeometryEffect(id: "theme", in: namespace)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Color.black.opacity(selected ? 0.8 : 0.25)).offset(x: 3, y: 3))
                        Text(option.title.uppercased())
                            .font(Typeface.pixel(9, bold: selected))
                            .tracking(0.6)
                            .foregroundStyle(selected ? Ink.accent : Palette.of(theme).muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("\(option.title) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.knob, value: theme)
    }
}

private struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        let palette = Palette.of(theme == .system ? .dark : theme)
        ZStack(alignment: .topLeading) {
            switch theme {
            case .system:
                // Half dark, half light: it follows the Mac.
                HStack(spacing: 0) {
                    Palette.of(.dark).window
                    Palette.of(.light).window
                }
            default:
                palette.window
            }
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Ink.field).frame(height: 18)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 2) {
                            ForEach(0..<4, id: \.self) { _ in SoftPixel(color: Ink.ink, size: 3) }
                        }
                        .padding(.leading, 5)
                    }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Ink.accent).frame(width: 18, height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(palette.raised).frame(height: 8)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(palette.line, lineWidth: 1))
                }
                RoundedRectangle(cornerRadius: 2).fill(palette.raised).frame(height: 6)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(palette.line, lineWidth: 1))
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

// MARK: - Buds field

/// The grain-green hero card with both buds and the case. The same in every theme.
struct BudsField: View {
    @Environment(BudsStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PixelTag(text: "Battery", style: .ink)
                Spacer()
                UpdatedAgo(date: store.updatedAt)
            }

            HStack(alignment: .bottom, spacing: 0) {
                BudColumn(side: .left)
                CaseColumn()
                BudColumn(side: .right)
            }

            if store.link.needsAction {
                LinkPrompt()
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background {
            ZStack {
                Ink.field
                GrainOverlay(opacity: 0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.black.opacity(0.85)).offset(x: 4, y: 4))
    }
}

private struct BudColumn: View {
    @Environment(BudsStore.self) private var store
    let side: BudSide

    var body: some View {
        let reading = store.battery[side == .left ? .left : .right]
        let awake = store.isLinked && reading != nil
        let tag = tag(reading: reading, awake: awake)

        VStack(spacing: 8) {
            PixelSprite(rows: Sprites.bud, palette: Sprites.palette(dimmed: !awake), pixel: 4, mirrored: side == .right)
                .offset(y: awake && store.placement[side] == .inEar ? -2 : 0)
                .animation(.knob, value: store.placement[side])

            LevelText(level: awake ? reading?.level : nil, charging: reading?.charging == true)

            PixelMeter(level: awake ? reading?.level : nil, block: 5,
                       on: (reading?.level ?? 100) <= 20 && reading?.charging != true ? Ink.hot : Ink.ink)

            HStack(spacing: 4) {
                Text(side == .left ? "L" : "R")
                    .font(Typeface.pixel(9, bold: true))
                    .foregroundStyle(Ink.ink.opacity(0.55))
                PixelTag(text: tag.text, style: tag.style)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.flatMap { awake ? "\(side == .left ? "Left" : "Right") bud, \($0.level) percent" : nil }
            ?? "\(side == .left ? "Left" : "Right") bud, not reporting")
    }

    private func tag(reading: BatteryReading?, awake: Bool) -> (text: String, style: PixelTag.Style) {
        guard store.isLinked else { return ("—", .ghost) }
        guard let reading, awake else { return ("asleep", .ghost) }
        if reading.charging { return ("charging", .pink) }
        if reading.level <= 20 { return ("low", .hot) }
        switch store.placement[side] {
        case .inEar: return ("in ear", .pink)
        case .outOfEar: return ("out", .ghost)
        case .inCase: return ("in case", .ghost)
        default: return ("ready", .ghost)
        }
    }
}

private struct CaseColumn: View {
    @Environment(BudsStore.self) private var store

    var body: some View {
        let reading = store.battery[.chargingCase]
        VStack(spacing: 8) {
            PixelSprite(rows: Sprites.chargingCase, palette: Sprites.palette(dimmed: reading == nil), pixel: 3)
                .padding(.bottom, 4)
            LevelText(level: reading?.level, charging: reading?.charging == true, size: 18)
            PixelMeter(level: reading?.level, segments: 6, block: 5)
            Text(reading == nil ? (store.isLinked ? "in case only" : " ") : "case")
                .font(Typeface.mono(9))
                .foregroundStyle(Ink.ink.opacity(0.55))
                .frame(height: 22, alignment: .top)
        }
        .frame(width: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.map { "Case, \($0.level) percent" } ?? "Case, not reporting")
    }
}

private struct LevelText: View {
    let level: Int?
    var charging = false
    var size: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if let level {
                Text("\(level)")
                    .font(Typeface.grotesk(size, .semibold))
                    .contentTransition(.numericText(value: Double(level)))
                Text("%")
                    .font(Typeface.grotesk(size * 0.5, .medium))
                    .opacity(0.7)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .padding(.leading, 2)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                Text("—")
                    .font(Typeface.grotesk(size, .medium))
                    .opacity(0.4)
            }
        }
        .monospacedDigit()
        .foregroundStyle(Ink.ink)
        .animation(.ui, value: level)
        .animation(.ui, value: charging)
    }
}

private struct UpdatedAgo: View {
    let date: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(label(now: context.date))
                .font(Typeface.mono(9.5))
                .foregroundStyle(Ink.ink.opacity(0.6))
        }
    }

    private func label(now: Date) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "live" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

/// Shown inside the field when there's no control link.
private struct LinkPrompt: View {
    @Environment(BudsStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(Typeface.grotesk(12.5, .medium))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            switch store.link {
            case .away:
                Button("Connect buds") { store.connect() }
                    .buttonStyle(ChunkyButtonStyle(fill: Ink.accent, foreground: Ink.ink))
            case .noBuds:
                Button("Open Bluetooth settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(ChunkyButtonStyle(fill: Ink.accent, foreground: Ink.ink))
            case .linking, .linked:
                EmptyView()
            }
        }
        .padding(.top, 2)
    }

    private var message: String {
        switch store.link {
        case .noBuds: "Pair your realme Buds with this Mac first, then they show up here."
        case .away: "Your buds aren't connected to this Mac. Open the case and connect."
        case .linking: "Opening the control channel…"
        case .linked: ""
        }
    }
}

// MARK: - Find & feedback

struct FindButton: View {
    @Environment(BudsStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.toggleRing()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.ringing ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .symbolEffect(.variableColor.iterative, isActive: store.ringing)
                    Text(store.ringing ? "Stop ringing" : "Find my buds")
                }
            }
            .buttonStyle(ChunkyButtonStyle(fill: store.ringing ? Ink.hot : nil, foreground: store.ringing ? Ink.ink : nil))
            Text("Loud chime. Take the buds out first.")
                .font(Typeface.mono(9.5))
                .foregroundStyle(palette.faint)
        }
    }
}

