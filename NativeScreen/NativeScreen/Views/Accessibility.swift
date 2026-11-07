import SwiftUI
import AppKit

/// VoiceOver helpers shared by the custom controls. Labels are English catalog keys translated with
/// `String.localizedUI`, like tooltips, so a label and its tooltip share one translation. See ADR-51 in `spec/06`.
extension View {
    /// For a view that takes clicks through an AppKit overlay or a gesture instead of a `Button`: VoiceOver sees one
    /// button, and pressing it (VO-Space) runs `action`. With no `label`, the button reads the text inside it.
    func accessibleButton(_ label: String? = nil, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        modifier(AccessibleButtonModifier(label: label, isSelected: isSelected, action: action))
    }

    /// Sets a translated label only when there is one, so the text inside the view is read otherwise.
    func accessibilityLabelIfAny(_ label: String?) -> some View {
        modifier(OptionalAccessibilityLabel(label: label?.localizedUI))
    }

    /// Same, for text that is already translated.
    func accessibilityLabelIfAny(translated label: String?) -> some View {
        modifier(OptionalAccessibilityLabel(label: label))
    }

    /// A drawing with no meaning of its own (dividers, glows, handles): VoiceOver skips it.
    func accessibilityDecorative() -> some View {
        accessibilityHidden(true)
    }
}

private struct AccessibleButtonModifier: ViewModifier {
    let label: String?
    let isSelected: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: label == nil ? .combine : .ignore)
            .accessibilityLabelIfAny(label)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(Text(verbatim: label))
        } else {
            content
        }
    }
}

public enum AccessibilityText {
    /// A tooltip without its shortcut suffix (`"Split clip (S)"` reads as "Split clip"), translated.
    public static func label(fromTooltip tooltip: String) -> String {
        let clean = InstantTooltipBubble.extractTrailingParenthesizedShortcut(from: tooltip, explicitBadge: nil).cleanText
        // Translate the full tooltip first: its key is the one in the catalog.
        let translated = tooltip.localizedUI
        if translated != tooltip {
            return InstantTooltipBubble.extractTrailingParenthesizedShortcut(from: translated, explicitBadge: nil).cleanText
        }
        return clean.localizedUI
    }

    /// A time on the timeline as words in the UI language, e.g. "1 minute, 5.2 seconds".
    public static func duration(ms: Double) -> String {
        let clamped = max(0, ms)
        let style: Duration.UnitsFormatStyle = clamped >= 60_000
            ? .units(allowed: [.minutes, .seconds], width: .wide, fractionalPart: .show(length: 1))
            : .units(allowed: [.seconds], width: .wide, fractionalPart: .show(length: 1))
        return Duration.milliseconds(Int64(clamped.rounded())).formatted(style)
    }

    /// "From 3.0 seconds to 5.5 seconds".
    public static func range(startMs: Double, endMs: Double) -> String {
        String(format: "From %@ to %@".localizedUI, duration(ms: startMs), duration(ms: endMs))
    }

    /// A 0...1 fraction as a percentage in the UI language.
    public static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Reads `text` out right away without moving the VoiceOver cursor (toasts, state changes).
    @MainActor
    public static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// The system's Reduce Motion setting, for AppKit code that animates on its own.
    @MainActor
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
