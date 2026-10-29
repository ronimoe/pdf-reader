import AppKit

/// Reduce Motion (spec §9.3, Rule 8): when it is on, nothing in Lectern animates.
public enum Motion {
    /// Replaces the system setting, for tests.
    public static var reduceMotionOverride: Bool?

    /// System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    public static var isReduced: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension NSView {
    /// Sets a layer's colour from a dynamic system colour, resolved in this view's appearance. A
    /// `CGColor` doesn't follow light and dark by itself, so call it again from
    /// `viewDidChangeEffectiveAppearance`.
    public func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}
