import SwiftUI
import AppKit

/// Appearance-adaptive colors for the editor chrome (`Settings > General > Appearance`).
///
/// The editor was designed dark: foregrounds are white at various opacities over near-black surfaces. `ink` replaces
/// that white (white in dark mode, near-black in light mode), and `Color.surface(...)` turns a dark surface into a
/// matching light one, so dark mode renders exactly as before.
///
/// Keep plain `.white` for content that sits on a fixed colored or dark background in both appearances: text on the
/// accent purple, timeline segment labels, controls drawn over the video preview, the recording bar and tooltips.
extension Color {
    /// Primary foreground of the editor chrome.
    static let ink = Color(nsColor: NSColor(name: "NativeScreenInk") { appearance in
        isDark(appearance) ? .white : NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    })

    /// A surface given by its dark-mode color; light mode uses the mirrored lightness with the same tint.
    static func surface(red: Double, green: Double, blue: Double, opacity: Double = 1) -> Color {
        Color(nsColor: .surface(red: red, green: green, blue: blue, alpha: opacity))
    }

    fileprivate static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension ShapeStyle where Self == Color {
    /// `.ink` wherever `.white` was used as a chrome foreground (`foregroundStyle(.ink.opacity(0.6))`).
    static var ink: Color { Color.ink }
}

extension NSColor {
    static func surface(red: Double, green: Double, blue: Double, alpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            if Color.isDark(appearance) {
                return NSColor(red: red, green: green, blue: blue, alpha: alpha)
            }
            // Mirror the lightness (0.05 -> 0.965, 0.20 -> 0.86) and keep the channel offsets, so a cool dark gray
            // becomes a cool light gray rather than a warm one.
            let lightness = (red + green + blue) / 3.0
            let mirrored = 1.0 - lightness * 0.7
            func channel(_ v: Double) -> Double { min(1.0, max(0.0, mirrored + (v - lightness) * 0.6)) }
            return NSColor(red: channel(red), green: channel(green), blue: channel(blue), alpha: alpha)
        }
    }
}
