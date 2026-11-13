#if LAA_BUILD
import Foundation

/// Rendering only: the actual model/provider identifiers stay unchanged.
enum LAAModelDisplay {
    static func name(_ identifier: String, label: String? = nil) -> String {
        if let label, !label.isEmpty, label != identifier, isDisplayLabel(label),
           !["gpt-", "deepseek-", "claude-", "opus-", "sonnet-", "haiku-", "fable-", "mythos-"].contains(where: { label.lowercased().hasPrefix($0) }) { return label }
        var model = identifier
        if let data = model.data(using: .utf8), let route = try? JSONDecoder().decode([String].self, from: data), route.count == 2 {
            model = route[1]
        }
        model = model.split(separator: "/").last.map(String.init) ?? model
        let lower = model.lowercased()
        if lower.hasPrefix("deepseek-v") {
            return "DeepSeek V" + model.dropFirst("deepseek-v".count).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        if lower.hasPrefix("gpt-") {
            return "GPT-" + model.dropFirst(4).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        for family in ["opus", "sonnet", "haiku", "fable", "mythos"] {
            if let range = lower.range(of: family + "-") {
                let version = lower[range.upperBound...].split(separator: "-")
                if version.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "." } }), !version.isEmpty {
                    return family.capitalized + " " + version.joined(separator: ".")
                }
            }
        }
        return "その他のモデル"
    }

    static func reasoning(_ value: String) -> String {
        ["none": "なし", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High",
         "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"][value] ?? "既定"
    }

    private static func isDisplayLabel(_ value: String) -> Bool {
        !value.contains("[") && !value.contains("{") && !value.contains("/") && !value.contains("_")
            && !value.lowercased().contains("laa-") && !value.lowercased().contains("opencode-go")
    }
}
#endif
