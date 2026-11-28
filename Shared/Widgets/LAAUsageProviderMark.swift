#if LAA_BUILD
import SwiftUI
import LAAKit
import WidgetKit

/// Usage measures the named provider, not whichever model or harness consumes its quota.
/// Gemini (the Google AI subscription's accounts) carries the Antigravity mark, the same
/// issued artwork as the model picker's Antigravity harness (owner, 2026-11-28: not the "G").
struct LAAUsageProviderMark: View {
    let provider: String
    var size: CGFloat = LAAComponentToken.ProviderCard.headerIcon

    static func asset(for provider: String) -> String? {
        switch provider {
        case "claude", "claude-api": "LAAClaudeMark"
        case LAAWidgetUsageBuilder.googleGroup: "LAAAntigravityMark"
        case "deepseek": "LAADeepSeekMark"
        default: nil
        }
    }

    private var neutralSymbol: String? {
        switch provider {
        case "muse": "waveform"
        default: nil
        }
    }

    var body: some View {
        Group {
            if let asset = Self.asset(for: provider) {
                if provider == "deepseek" {
                    markImage(Image(asset).renderingMode(.template))
                        .foregroundStyle(LAAColorValues.deepSeekBrand)
                } else {
                    markImage(Image(asset).renderingMode(.original))
                }
            } else if let neutralSymbol {
                Image(systemName: neutralSymbol)
                    .font(.system(size: size))
                    .foregroundStyle(LAAColor.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func markImage(_ image: Image) -> some View {
        #if LAA_WIDGET_EXTENSION
        if #available(iOS 18.0, *) {
            image.resizable().widgetAccentedRenderingMode(.fullColor).aspectRatio(contentMode: .fit)
        } else {
            image.resizable().scaledToFit()
        }
        #else
        image.resizable().scaledToFit()
        #endif
    }
}
#endif
