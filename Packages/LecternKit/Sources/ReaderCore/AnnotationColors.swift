/// The six annotation colours (B4). Each has a name, for VoiceOver and the annotation list, so
/// colour is never the only way to tell annotations apart (Rule 8). Yellow is the default.
public enum AnnotationColorPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case yellow, green, blue, pink, purple, red

    public static let `default` = AnnotationColorPreset.yellow

    public var name: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        case .red: "Red"
        }
    }

    /// Red, green and blue in 0…1, as written to the annotation's `/C`.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow: (1, 0.85, 0)
        case .green: (0.45, 0.85, 0.35)
        case .blue: (0.35, 0.65, 1)
        case .pink: (1, 0.5, 0.75)
        case .purple: (0.7, 0.5, 1)
        case .red: (1, 0.3, 0.25)
        }
    }

    /// The preset whose colour is within `tolerance` of each component, or nil (another app's colour).
    public static func matching(red: Double, green: Double, blue: Double, tolerance: Double = 0.02) -> AnnotationColorPreset? {
        allCases.first {
            let c = $0.rgb
            return abs(c.red - red) <= tolerance && abs(c.green - green) <= tolerance && abs(c.blue - blue) <= tolerance
        }
    }

    /// A name for any colour: the preset's, or the nearest basic hue for colours from other apps
    /// ("Orange", "Grey"…), so the list and VoiceOver never fall back to a number.
    public static func describe(red: Double, green: Double, blue: Double) -> String {
        if let preset = matching(red: red, green: green, blue: blue) { return preset.name }
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        if delta < 0.08 {
            return maximum > 0.9 ? "White" : (maximum < 0.15 ? "Black" : "Grey")
        }
        var hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / delta)
        } else if maximum == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 345...: return "Red"
        case ..<40: return "Orange"
        case ..<70: return "Yellow"
        case ..<170: return "Green"
        case ..<200: return "Cyan"
        case ..<255: return "Blue"
        case ..<290: return "Purple"
        default: return "Pink"
        }
    }
}

/// What kind of annotation something is, in words (the annotation list and VoiceOver). Shapes, not
/// colours, tell highlight, underline and strike-through apart (B4, Rule 8).
public enum AnnotationKindName {
    public static func name(forSubtype subtype: String) -> String {
        switch subtype.hasPrefix("/") ? String(subtype.dropFirst()) : subtype {
        case "Highlight": "Highlight"
        case "Underline": "Underline"
        case "StrikeOut": "Strike Through"
        case "Squiggly": "Squiggly Underline"
        case "Text": "Note"
        case "FreeText": "Text Box"
        case "Ink": "Drawing"
        case "Square": "Rectangle"
        case "Circle": "Oval"
        case "Line": "Line"
        case "Polygon": "Polygon"
        case "PolyLine": "Polyline"
        case "Stamp": "Stamp"
        case "Caret": "Caret"
        case "FileAttachment": "Attached File"
        case "Sound": "Sound"
        case "Redact": "Redaction"
        case let other: other.isEmpty ? "Annotation" : other
        }
    }

    /// Subtypes the reader lists and lets the user select, edit and delete. Links, form widgets
    /// and popups are part of other features (or of their parent annotation), so they're left out.
    public static func isListed(subtype: String) -> Bool {
        let s = subtype.hasPrefix("/") ? String(subtype.dropFirst()) : subtype
        return !["Link", "Widget", "Popup", "", "PrinterMark", "TrapNet", "Watermark", "3D", "Screen", "Movie", "RichMedia"].contains(s)
    }

    /// Subtypes whose colour can be changed: text markup and notes. The writer regenerates their
    /// appearance; for other subtypes with an appearance it refuses (PDFSave, M4a).
    public static func allowsColorChange(subtype: String) -> Bool {
        let s = subtype.hasPrefix("/") ? String(subtype.dropFirst()) : subtype
        return ["Highlight", "Underline", "StrikeOut", "Text"].contains(s)
    }
}
