#if LAA_BUILD
import Foundation

/// Rendering only: the actual model/provider identifiers stay unchanged.
enum LAAModelDisplay {
    static func name(_ identifier: String, label: String? = nil) -> String {
        if let label, !label.isEmpty, label != identifier, isDisplayLabel(label),
           !["gpt-", "deepseek-", "claude-", "opus-", "sonnet-", "haiku-", "fable-", "mythos-", "gemini-"].contains(where: { label.lowercased().hasPrefix($0) }) { return label }
        var model = identifier
        if let data = model.data(using: .utf8), let route = try? JSONDecoder().decode([String].self, from: data), route.count == 2 {
            model = route[1]
        }
        model = model.split(separator: "/").last.map(String.init) ?? model
        // A paid API route's prefix: "openai-api:gpt-5.5", "anthropic:claude-opus-5-5".
        if let colon = model.firstIndex(of: ":"), ["openai-api", "openai", "anthropic", "google", "gemini"].contains(model[..<colon].lowercased()) {
            model = String(model[model.index(after: colon)...])
        }
        let lower = model.lowercased()
        if lower.hasPrefix("gemini-") {
            let words = model.dropFirst("gemini-".count).split(separator: "-")
                .filter { !["low", "medium", "high", "xhigh", "max"].contains($0.lowercased()) }
            return (["Gemini"] + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
        }
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
        return "Other Models"
    }

    static func reasoning(_ value: String) -> String {
        ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High",
         "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"][value] ?? "Default"
    }

    private static func isDisplayLabel(_ value: String) -> Bool {
        !value.contains("[") && !value.contains("{") && !value.contains("/") && !value.contains("_")
            && !value.lowercased().contains("laa-") && !value.lowercased().contains("opencode-go")
    }
}
#endif
