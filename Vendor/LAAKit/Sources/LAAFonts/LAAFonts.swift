import CoreText
import Foundation
import LAATokens

/// Registers the bundled typefaces (SIL OFL 1.1, see LICENSES.md) once per process, from the package
/// bundle. Nothing is downloaded. App targets only: widgets, keyboards and Watch faces use system type.
public enum LAAFonts {
    public struct Face: Sendable, Hashable {
        public let file: String
        /// PostScript name Core Text resolves after registration.
        public let postScriptName: String
        public let family: String
    }

    /// Every bundled face. Variable fonts expose their default instance under this name; weights and
    /// optical size are set through the variation axes by `LAAType`.
    public static let faces: [Face] = [
        Face(file: "Newsreader[opsz,wght].ttf", postScriptName: "Newsreader16pt-Regular", family: "Newsreader"),
        Face(file: "Newsreader-Italic[opsz,wght].ttf", postScriptName: "Newsreader16pt-Italic", family: "Newsreader"),
        Face(file: "ShipporiMincho-Medium.ttf", postScriptName: "ShipporiMincho-Medium", family: "Shippori Mincho"),
        Face(file: "ShipporiMincho-SemiBold.ttf", postScriptName: "ShipporiMincho-SemiBold", family: "Shippori Mincho"),
        Face(file: "CormorantGaramond[wght].ttf", postScriptName: "CormorantGaramond-Regular", family: "Cormorant Garamond"),
    ]

    public enum Failure: Error, Sendable, Hashable {
        case missing(String)
        case rejected(String, Int)
    }

    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    /// Call once at launch (idempotent, thread-safe). Returns the faces that failed; empty means all resolved.
    @discardableResult
    public static func register() -> [Failure] {
        lock.lock(); defer { lock.unlock() }
        if registered { return [] }
        var failures: [Failure] = []
        for face in faces {
            guard let url = Bundle.module.url(forResource: face.file, withExtension: nil, subdirectory: "Fonts")
                    ?? Bundle.module.url(forResource: face.file, withExtension: nil) else {
                failures.append(.missing(face.file)); continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1
                // 105 = already registered (another copy of the kit in the same process): not a failure.
                if code != 105 { failures.append(.rejected(face.file, code)) }
            }
        }
        registered = failures.isEmpty
        return failures
    }

    /// True when Core Text resolves the face by PostScript name to the bundled file (not a fallback).
    public static func resolves(_ face: Face) -> Bool {
        let font = CTFontCreateWithName(face.postScriptName as CFString, 17, nil)
        return (CTFontCopyPostScriptName(font) as String) == face.postScriptName
    }
}
