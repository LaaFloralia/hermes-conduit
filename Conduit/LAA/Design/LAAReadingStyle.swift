#if LAA_BUILD
import SwiftUI
import UIKit

/// The reading register's one place (provisional v2.1 delta, ADVICE-V2 §3.2
/// `font.reading`, §3.3 type scale). Every size, line box and measure the
/// transcript, the owner's bubble and the composer read comes from here, named
/// after the kit tokens, so the swap to `kit-v0.1.0` is mechanical.
enum LAAReadingStyle {
    /// Catalyst draws UIKit points at 0.77 Mac points (`LAAType`); the Mac
    /// tokens are Mac points, so UIKit sizes are the token over 0.77.
    #if targetEnvironment(macCatalyst)
    static let platformScale: CGFloat = 1 / 0.77
    #else
    static let platformScale: CGFloat = 1
    #endif

    /// `canvas.app-1280.readingMeasure`: the Mac's prose column, left-anchored.
    static var macMeasure: CGFloat { 680 * platformScale }
}
#endif
