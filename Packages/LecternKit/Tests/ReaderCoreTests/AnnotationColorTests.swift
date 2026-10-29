import Testing
@testable import ReaderCore

@Suite struct AnnotationColorTests {
    @Test func sixNamedPresetsWithYellowFirst() {
        #expect(AnnotationColorPreset.allCases.count == 6)
        #expect(AnnotationColorPreset.default == .yellow)
        #expect(AnnotationColorPreset.allCases.first == .yellow)
        #expect(Set(AnnotationColorPreset.allCases.map(\.name)).count == 6)
    }

    @Test func presetsMatchTheirOwnColour() {
        for preset in AnnotationColorPreset.allCases {
            let c = preset.rgb
            #expect(AnnotationColorPreset.matching(red: c.red, green: c.green, blue: c.blue) == preset)
            #expect(AnnotationColorPreset.describe(red: c.red, green: c.green, blue: c.blue) == preset.name)
        }
    }

    @Test func otherColoursGetAHueName() {
        #expect(AnnotationColorPreset.describe(red: 1, green: 0.5, blue: 0) == "Orange")
        #expect(AnnotationColorPreset.describe(red: 0.5, green: 0.5, blue: 0.5) == "Grey")
        #expect(AnnotationColorPreset.describe(red: 0, green: 0, blue: 0) == "Black")
        #expect(AnnotationColorPreset.describe(red: 0, green: 0.2, blue: 0.9) == "Blue")
        #expect(AnnotationColorPreset.describe(red: 1, green: 1, blue: 0) == "Yellow")
        #expect(AnnotationColorPreset.matching(red: 1, green: 1, blue: 0) == nil)
    }

    @Test func kindNamesAndRules() {
        #expect(AnnotationKindName.name(forSubtype: "/StrikeOut") == "Strike Through")
        #expect(AnnotationKindName.name(forSubtype: "Text") == "Note")
        #expect(!AnnotationKindName.isListed(subtype: "Link"))
        #expect(!AnnotationKindName.isListed(subtype: "/Widget"))
        #expect(!AnnotationKindName.isListed(subtype: "Popup"))
        #expect(AnnotationKindName.isListed(subtype: "Ink"))
        #expect(AnnotationKindName.allowsColorChange(subtype: "Highlight"))
        #expect(AnnotationKindName.allowsColorChange(subtype: "Text"))
        #expect(!AnnotationKindName.allowsColorChange(subtype: "Square"))
        #expect(!AnnotationKindName.allowsColorChange(subtype: "Squiggly"))
    }
}
