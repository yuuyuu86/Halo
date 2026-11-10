import SwiftUI

/// Halo's visual language.
///
/// The look is deliberately *not* a pie chart: a thin luminous ring with
/// free-floating nodes on its circumference, lit from the selection like a
/// filament. Warm gold as the primary light, cool violet as its echo.
struct HaloTheme {

    var accent: Color
    var secondary: Color

    static func from(_ appearance: Appearance) -> HaloTheme {
        HaloTheme(accent: Color(hex: appearance.accentHex) ?? Color(hex: "#FFC46B")!,
                  secondary: Color(hex: appearance.secondaryHex) ?? Color(hex: "#9B8CFF")!)
    }

    // Structural colours — tuned for legibility over arbitrary desktop content.
    let veil          = Color.black.opacity(0.20)
    let ringBase      = Color.white.opacity(0.14)
    let nodeFill      = Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.72)
    let nodeStroke    = Color.white.opacity(0.16)
    let coreFill      = Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.80)
    let label         = Color.white.opacity(0.55)
    let labelSelected = Color.white.opacity(0.96)
    let glyph         = Color.white.opacity(0.80)

    /// Gradient painted along the lit arc under the selected node.
    func arcGradient(at angle: Angle) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: accent.opacity(0.0), location: 0.00),
                .init(color: accent.opacity(0.9), location: 0.50),
                .init(color: secondary.opacity(0.0), location: 1.00)
            ]),
            center: .center,
            angle: angle
        )
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0,
                  opacity: 1.0)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}
