#if LAA_BUILD
import Foundation
import os
import UIKit

private let deviceReportLog = Logger(subsystem: "com.laa.hortensia", category: "DeviceReports")

/// Sends the MetricKit reports this device keeps (crashes with their call
/// stacks, hangs, slow launches, and each day's exit reasons) to the paired Mac's Bridge
/// (`POST /v1/device-reports`), each once. TestFlight's crash feed needs the
/// owner to tap Share and often stays empty; this needs nothing from them.
enum LAADeviceReportUpload {
    private struct Stored: Decodable { let id: String; let stored: Bool }

    /// The Bridge takes up to 4 MiB a request; a larger report stays on the
    /// device for Diagnostics & logs.
    static let maxBodyBytes = 4 * 1024 * 1024 - 4096

    @MainActor private static var observer: NSObjectProtocol?

    @MainActor static func start() {
        MetricKitReports.shared.sendDiagnostics(with: send)
        guard observer == nil else { return }
        // Not paired yet, or offline at launch: try again when the app is opened.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MetricKitReports.shared.sendDiagnostics(with: send)
        }
    }

    /// The request body: the payload as iOS wrote it, and which build sent it.
    static func body(name: String, json: Data, appVersion: String = MetricKitReportStore.appVersion) -> Data? {
        guard let payload = try? JSONSerialization.jsonObject(with: json), payload is [String: Any] else { return nil }
        let kind = name.hasPrefix("metrics-") ? "metrics" : "diagnostics"
        let object: [String: Any] = ["kind": kind, "name": name, "appVersion": appVersion, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= maxBodyBytes else { return nil }
        return data
    }

    /// Whether this report is done with: sent, or one the Bridge will never
    /// take (too large, refused). False keeps it for the next try.
    @Sendable static func send(name: String, json: Data) async -> Bool {
        guard let credentials = try? LAABridgeKeychain().read() else { return false }
        guard let body = body(name: name, json: json) else {
            deviceReportLog.error("A diagnostic was too large or not JSON; kept on the device only")
            return true
        }
        do {
            let response: LAABridgeResponse<Stored> = try await LAABridgeClient().request(
                method: "POST", path: "/v1/device-reports", jsonBody: body, credentials: credentials, timeout: 30)
            deviceReportLog.info("diagnostic sent, stored \(response.data.stored, privacy: .public)")
            return true
        } catch let error as LAABridgeHTTPError where [400, 403, 413].contains(error.status) {
            deviceReportLog.error("Bridge refused a diagnostic: \(error.status, privacy: .public)")
            return true
        } catch {
            return false
        }
    }
}
#endif
