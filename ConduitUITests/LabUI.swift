import Foundation
import XCTest

/// Xcode's TEST_RUNNER_ environment reaches the XCTest process, not the app.
/// Forward only the lane id and fixture origins. Pairing still goes through
/// the app's normal enrollment UI and persists in a per-app lab Keychain.
enum LabUI {
    static let environment = ProcessInfo.processInfo.environment
    static let id = environment["LAA_LANE_ID"]
    static let active = id != nil
    static let bridge = environment["LAA_LANE_BRIDGE"]
    static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    static func fixture(_ name: String) -> String? {
        environment["LAA_LANE_FIXTURE_" + name.uppercased().replacingOccurrences(of: "-", with: "_")]
    }

    static func origin(_ name: String, legacyPort: Int) -> String? {
        active ? fixture(name) : "http://127.0.0.1:\(legacyPort)"
    }

    static func request(_ origin: String?, _ path: String) throws -> URLRequest {
        guard let origin, let url = URL(string: origin + path), url.scheme == "http",
              url.host == "127.0.0.1", url.user == nil, url.password == nil, let port = url.port,
              ![9137, 9119, 8443, 8444, 8445, 8384, 8081].contains(port) else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let id { request.setValue(id, forHTTPHeaderField: "X-LAA-Lane") }
        return request
    }

    static func matches(_ response: URLResponse?, acceptHTTPError: Bool = false) -> Bool {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) || (acceptHTTPError && (400..<600).contains(response.statusCode)) else { return false }
        return id.map { response.value(forHTTPHeaderField: "X-LAA-Lane") == $0 } ?? true
    }

    static func data(_ origin: String?, _ path: String, method: String = "GET", acceptHTTPError: Bool = false) throws -> Data {
        var request = try request(origin, path)
        request.httpMethod = method
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let task = session.dataTask(with: request) { data, response, _ in
            if matches(response, acceptHTTPError: acceptHTTPError) { result.data = data }
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 22) == .success, let data = result.data else {
            task.cancel()
            throw URLError(.badServerResponse)
        }
        return data
    }

    private final class ResultBox: @unchecked Sendable { var data: Data? }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

extension XCUIApplication {
    func launchInLab() {
        var values = launchEnvironment
        if LabUI.active {
            values["LAA_LANE_ID"] = LabUI.id
            values["LAA_LANE_BRIDGE"] = LabUI.bridge
            for (key, value) in LabUI.environment where key.hasPrefix("LAA_LANE_FIXTURE_") { values[key] = value }
        }
        if LabUI.active || launchArguments.contains("-LAA_UI_TEST_ISOLATED_BRIDGE") {
            if values["LAA_LAB_KEYCHAIN_NAMESPACE"] == nil { values["LAA_LAB_KEYCHAIN_NAMESPACE"] = UUID().uuidString }
        }
        launchEnvironment = values
        launch()
    }
}
