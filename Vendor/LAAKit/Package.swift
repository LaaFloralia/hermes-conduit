// swift-tools-version: 6.0
// LAA Kit — generated design tokens, bundled typefaces and shared SwiftUI components.
// Tokens come from /Users/laa/hq/design/tokens.json via scripts/generate.py. No business logic,
// login or networking lives here.
import PackageDescription

let package = Package(
    name: "LAAKit",
    defaultLocalization: "ja",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        // Tokens only: safe for widgets, extensions, keyboards and Watch faces (no fonts, no UIKit).
        .library(name: "LAATokens", targets: ["LAATokens"]),
        // Bundled OFL typefaces and their one-time registration (app targets only).
        .library(name: "LAAFonts", targets: ["LAAFonts"]),
        // Components: transcript, working strip, subagent group, usage card, orb, picker, glass.
        .library(name: "LAAKit", targets: ["LAAKit"]),
    ],
    targets: [
        .target(name: "LAATokens"),
        .target(name: "LAAFonts", dependencies: ["LAATokens"], resources: [.copy("Resources/Fonts")]),
        // LAAKit does not link LAAFonts, so widgets and Watch apps stay small; apps add LAAFonts and call register().
        .target(name: "LAAKit", dependencies: ["LAATokens"], resources: [.process("Resources")]),
        .testTarget(name: "LAATokensTests", dependencies: ["LAATokens"]),
        .testTarget(name: "LAAFontsTests", dependencies: ["LAAFonts"]),
        .testTarget(name: "LAAKitTests", dependencies: ["LAAKit", "LAAFonts"]),
    ]
)
