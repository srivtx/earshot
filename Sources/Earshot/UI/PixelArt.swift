import SwiftUI

/// Draws a sprite from rows of characters, one character per pixel. Unmapped characters are clear.
struct PixelSprite: View {
    let rows: [String]
    let palette: [Character: Color]
    var pixel: CGFloat = 4
    var mirrored = false

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() {
                    guard let color = palette[char] else { continue }
                    let column = mirrored ? width - 1 - x : x
                    // Soft pixels: each cell has rounded corners, so the sprite reads as rounded blocks.
                    let cell = CGRect(x: CGFloat(column) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)
                    context.fill(Path(roundedRect: cell, cornerRadius: pixel * 0.3, style: .continuous), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(width) * pixel, height: CGFloat(rows.count) * pixel)
        .fixedSize()
    }
}

enum Sprites {
    /// A stem earbud with its tip on the right. Mirror it for the right bud.
    static let bud = [
        "....+##.....",
        "..++####-...",
        ".+#######-x.",
        ".+######--xx",
        ".+######--xx",
        ".+#######-x.",
        "..+######-..",
        "...+####-...",
        "...+###-....",
        "...+###-....",
        "...+###-....",
        "...+###-....",
        "...+###-....",
        "...+#o#-....",
        "....---.....",
    ]

    static let chargingCase = [
        "...++++++++++++++...",
        ".++##############-..",
        "+#################-.",
        "+#################-.",
        "=================== ",
        "+#################-.",
        "+########oo#######-.",
        "+#################-.",
        ".+###############-..",
        "...-------------....",
    ]

    /// The bud and case colours, printed on the green field.
    static func palette(dimmed: Bool) -> [Character: Color] {
        let alpha = dimmed ? 0.32 : 1
        return [
            "#": Color(hex: 0xF4FFF6, opacity: alpha),
            "+": Color.white.opacity(alpha),
            "-": Color(hex: 0xA9C4B1, opacity: alpha),
            "=": Color(hex: 0x7F9C88, opacity: alpha),
            "o": Ink.ink.opacity(alpha),
            "x": (dimmed ? Ink.ink.opacity(0.25) : Ink.accent),
        ]
    }

    /// The Earshot mark: a tilted pixel cluster in pink and green.
    static let mark = [
        "pp.",
        "pg.",
        "..g",
    ]
    static let markPalette: [Character: Color] = ["p": Ink.accent, "g": Ink.tested]

    /// The settings gear, drawn in soft pixels.
    static let gear = [
        "...#...",
        ".#####.",
        ".##.##.",
        "##...##",
        ".##.##.",
        ".#####.",
        "...#...",
    ]
}
