import CoreText
import Foundation
import Testing
@testable import LAAFonts

/// The bundled faces register from the package bundle (no network) and Core Text resolves them by name.
struct FontRegistrationTests {
    @Test func registersEveryBundledFace() {
        #expect(LAAFonts.register().isEmpty)
        #expect(LAAFonts.register().isEmpty) // idempotent
    }

    @Test(arguments: LAAFonts.faces)
    func resolvesByPostScriptName(_ face: LAAFonts.Face) {
        _ = LAAFonts.register()
        #expect(LAAFonts.resolves(face), "\(face.postScriptName) did not resolve")
        let font = CTFontCreateWithName(face.postScriptName as CFString, 17, nil)
        #expect((CTFontCopyFamilyName(font) as String) == face.family)
    }

    @Test func newsreaderAndShipporiResolveByFamilyAndCascade() throws {
        _ = LAAFonts.register()
        let latin = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "Newsreader"] as CFDictionary)
        let japanese = CTFontDescriptorCreateWithNameAndSize("ShipporiMincho-Medium" as CFString, 17)
        let cascaded = CTFontDescriptorCreateCopyWithAttributes(latin, [kCTFontCascadeListAttribute: [japanese]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(cascaded, 17, nil)
        #expect((CTFontCopyFamilyName(font) as String) == "Newsreader")
        let text = "読む" as CFString
        let fallback = CTFontCreateForString(font, text, CFRange(location: 0, length: CFStringGetLength(text)))
        #expect((CTFontCopyPostScriptName(fallback) as String) == "ShipporiMincho-Medium")
    }

    @Test func bundledFilesAreTheLockedOnes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("kit.lock.json"))) as? [String: Any]
        let files = try #require(lock?["files"] as? [String: String])
        for face in LAAFonts.faces {
            #expect(files["Sources/LAAFonts/Resources/Fonts/\(face.file)"] != nil, "\(face.file) not in kit.lock.json")
        }
    }
}
