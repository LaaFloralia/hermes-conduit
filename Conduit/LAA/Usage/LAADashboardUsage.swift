#if LAA_BUILD
import CoreFoundation
import Foundation

/// A dashboard model row stays separate from Bridge subscription quotas.
struct LAADashboardUsageRow: Identifiable, Equatable {
    let id: String
    let provider: String?
    let model: String
    let inputTokens: Double?
    let outputTokens: Double?
    let actualCost: Double?
    let estimatedCost: Double?

    static func parse(usage: [String: Any], models: [String: Any]?) throws -> [Self] {
        guard let rows = (models?["models"] as? [[String: Any]]) ?? (usage["by_model"] as? [[String: Any]]) else {
            throw LAAUsageProblem.dashboardFailed
        }
        return rows.enumerated().compactMap { index, row in
            guard let model = nonempty(row["model"]) else { return nil }
            let provider = nonempty(row["provider"]) ?? nonempty(row["billing_provider"])
            let actual = number(row["actual_cost"])
            // Hermes COALESCEs missing billed cost to zero; it cannot establish a billed zero.
            return Self(id: "\(index):\(provider ?? ""):\(model)", provider: provider, model: model,
                        inputTokens: number(row["input_tokens"]), outputTokens: number(row["output_tokens"]),
                        actualCost: actual.flatMap { $0 > 0 ? $0 : nil },
                        estimatedCost: number(row["estimated_cost"]))
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }
}

@MainActor
enum LAADashboardUsage {
    static let days = 30

    static func load(from appState: AppState) async throws -> [LAADashboardUsageRow] {
        guard appState.isConnected, let bridge = appState.dashboardTicketBridge else {
            throw LAAUsageProblem.dashboardNotConnected
        }
        let profile = appState.activeProfile
        let dashboardID = appState.activeDashboardID
        let usage: [String: Any]
        do {
            usage = try await bridge.requestJSON(path: UsageReport.path(UsageReport.usagePath, days: days, profile: profile))
        } catch let error as DashboardTicketBridgeError where GeminiLiveTokenClient.isMissingRoute(error) {
            throw LAAUsageProblem.dashboardUnsupported
        } catch DashboardTicketBridgeError.signInRequired {
            throw LAAUsageProblem.dashboardSignIn
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LAAUsageProblem.dashboardFailed
        }
        let models = try? await bridge.requestJSON(path: UsageReport.path(UsageReport.modelsPath, days: days, profile: profile))
        guard !Task.isCancelled, appState.dashboardTicketBridge === bridge,
              appState.activeDashboardID == dashboardID, appState.activeProfile == profile else {
            throw CancellationError()
        }
        return try LAADashboardUsageRow.parse(usage: usage, models: models)
    }
}
#endif
