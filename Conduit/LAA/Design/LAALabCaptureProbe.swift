#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit

/// Lab-only data and a read of effective traits, not requested launch values.
enum LAALabCaptureFixture {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-LAA_LAB_CAPTURE")
    static let longJapanese = enabled && ProcessInfo.processInfo.arguments.contains("-LAA_LAB_LONG_JAPANESE")
    static let name = "次の四半期に向けた制作計画と関係者への確認事項をまとめた長い日本語の名前"
    static let paragraph = "関係者が順番を迷わないよう、変更の理由と確認する箇所を資料にまとめます。"

    static func expanded(_ text: String) -> String { longJapanese ? name + "｜" + text : text }
}

struct LAALabCaptureProbe: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var size
    @Environment(\.accessibilityReduceMotion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var transparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let traits = [scheme == .dark ? "dark" : "light", String(describing: size),
                      String(motion), String(transparency), String(contrast == .increased),
                      String(UIAccessibility.isReduceMotionEnabled), String(UIAccessibility.isReduceTransparencyEnabled)]
        Text(verbatim: traits.joined(separator: ","))
            .font(.system(size: 1)).frame(width: 2, height: 2).opacity(0.02)
            .accessibilityLabel(Text(verbatim: traits.joined(separator: ",")))
            .accessibilityIdentifier("laa.lab.capture.traits")
            .allowsHitTesting(false)
    }
}
#endif
