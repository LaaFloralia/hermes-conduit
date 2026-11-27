#if LAA_BUILD
import SwiftUI
import LAAKit
import WidgetKit

/// Usage measures the named provider, not whichever model or harness consumes its quota.
struct LAAUsageProviderMark: View {
    let provider: String

    static func asset(for provider: String) -> String? {
        switch provider {
        case "codex", "openai-api": "LAAOpenAIMark"
        case "claude", "claude-api": "LAAClaudeMark"
        case "deepseek": "LAADeepSeekMark"
        default: nil
        }
    }

    private var neutralSymbol: String {
        switch provider {
        case "google-ai-pro": "g.circle"
        case "muse": "waveform"
        default: "circle.dashed"
        }
    }

    var body: some View {
        let size = LAAComponentToken.ProviderCard.headerIcon
        Group {
            if let asset = Self.asset(for: provider) {
                let image = Image(asset).renderingMode(.original).resizable()
                #if LAA_WIDGET_EXTENSION
                if #available(iOS 18.0, *) {
                    image.widgetAccentedRenderingMode(.fullColor).aspectRatio(contentMode: .fit)
                } else {
                    image.scaledToFit()
                }
                #else
                image.scaledToFit()
                #endif
            } else {
                Image(systemName: neutralSymbol)
                    .font(.system(size: size))
                    .foregroundStyle(LAAColor.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
