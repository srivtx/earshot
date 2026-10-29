import AppKit
import CoreText
import SwiftUI

// MARK: - Brand

/// Colours that never change with the theme: oauth-ready's pink, ink and grain green.
enum Ink {
    static let accent = Color(hex: 0xF7B9E4)
    static let hot = Color(hex: 0xFF6FCF)
    static let field = Color(hex: 0x2E9A5D)
    /// Dark ink printed on pink and green.
    static let ink = Color(hex: 0x13221A)
    static let tested = Color(hex: 0x62E08A)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Themes

enum Theme: String, CaseIterable, Identifiable {
    /// Follows the Mac's light or dark appearance.
    case system, dark, light

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Everything that changes between themes. Brand colours stay in `Ink`.
struct Palette {
    let theme: Theme
    let text: Color
    let muted: Color
    let faint: Color
    let line: Color
    /// Panel fill in the solid themes.
    let surface: Color
    /// Hover, pressed and off-switch fill.
    let raised: Color
    /// Window fill.
    let window: Color
    /// Pink for text and thin marks: the brand pink on dark, a deeper pink that reads on light.
    let accentText: Color

    var isDark: Bool { theme == .dark }

    /// `systemIsDark` resolves the System theme to the Mac's current appearance.
    static func of(_ theme: Theme, systemIsDark: Bool = true) -> Palette {
        switch theme {
        case .system:
            of(systemIsDark ? .dark : .light)
        case .dark:
            Palette(theme: theme, text: Color(hex: 0xECEFE9), muted: Color(hex: 0x93A197), faint: Color(hex: 0x5D6C62),
                    line: Color(hex: 0x22322A), surface: Color(hex: 0x101812), raised: Color(hex: 0x18241C), window: Color(hex: 0x0A100C),
                    accentText: Ink.accent)
        case .light:
            Palette(theme: theme, text: Color(hex: 0x13221A), muted: Color(hex: 0x4E5D53), faint: Color(hex: 0x8A978E),
                    line: Color(hex: 0xD6DCD4), surface: .white, raised: Color(hex: 0xEDF1EB), window: Color(hex: 0xF3F5F0),
                    accentText: Color(hex: 0xC2378F))
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.of(.dark)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// A panel: a flat fill with a hairline.
struct Surface<S: Shape>: ViewModifier {
    @Environment(\.palette) private var palette
    let shape: S
    var raised = false

    func body(content: Content) -> some View {
        content
            .background(raised ? palette.raised : palette.surface, in: shape)
            .overlay(shape.stroke(palette.line, lineWidth: 1))
    }
}

/// Corner radii: soft, never sharp, and tighter for smaller things.
enum Radius {
    static let tag: CGFloat = 3
    static let control: CGFloat = 8
    static let group: CGFloat = 10
    static let card: CGFloat = 14
}

extension View {
    func surface(radius: CGFloat = Radius.control, raised: Bool = false) -> some View {
        modifier(Surface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), raised: raised))
    }
}

/// The window fill for the current theme.
struct WindowBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        palette.window
    }
}

// MARK: - Motion

extension Animation {
    /// Morphotype's ease: a quick start that settles softly.
    static let ui = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)
    /// For things that move under the finger: knobs, thumbs, selection blocks.
    static let knob = Animation.spring(response: 0.32, dampingFraction: 0.78)
}

// MARK: - Type

enum Typeface {
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", fixedSize: size)
    }

    static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Space Grotesk", fixedSize: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", fixedSize: size).weight(weight)
    }

    /// Registers the bundled fonts for this process only.
    static func registerBundled() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Grain

/// Film/paper grain, as in risograph prints. Generated once and tiled.
enum Grain {
    static let image: NSImage = {
        let size = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceWhite, bytesPerRow: size * 2, bitsPerPixel: 16),
              let data = rep.bitmapData else { return NSImage() }
        var generator = SystemRandomNumberGenerator()
        for i in 0..<(size * size) {
            data[i * 2] = UInt8.random(in: 0...255, using: &generator)
            data[i * 2 + 1] = UInt8.random(in: 0...200, using: &generator)
        }
        let image = NSImage(size: NSSize(width: size / 2, height: size / 2))
        image.addRepresentation(rep)
        return image
    }()
}

struct GrainOverlay: View {
    var opacity: Double = 0.5

    var body: some View {
        Image(nsImage: Grain.image)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

// MARK: - Screenshots

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set while rendering README screenshots: scroll views and menus draw as plain views.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
