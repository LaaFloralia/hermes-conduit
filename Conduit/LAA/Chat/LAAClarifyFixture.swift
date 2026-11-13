#if DEBUG && LAA_BUILD
import Foundation

/// Synthetic server frames through the production client for UI input tests.
final class LAAClarifyFixtureSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var onAnswer: (@MainActor (String, String) -> Void)?
    private let lock = NSLock()
    private var frames: [String] = []
    private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        lock.lock(); let parked = continuation; continuation = nil; lock.unlock()
        parked?.resume(throwing: URLError(.cancelled))
    }
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
        guard case .string(let text) = message,
              let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let id = frame["id"] as? String, let result = frame["result"] as? [String: Any], let answer = result["answer"] as? String {
            Task { @MainActor in self.onAnswer?(id, answer) }
        } else if let id = frame["id"] as? Int {
            deliver(["jsonrpc": "2.0", "id": id, "result": [:]])
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { parked in
            lock.lock()
            if !frames.isEmpty { let frame = frames.removeFirst(); lock.unlock(); parked.resume(returning: .string(frame)) }
            else { continuation = parked; lock.unlock() }
        }
    }
    func deliver(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let frame = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if let parked = continuation { continuation = nil; lock.unlock(); parked.resume(returning: .string(frame)) }
        else { frames.append(frame); lock.unlock() }
    }
}
final class LAAClarifyFixtureTransport: HermesWebSocketTransport {
    let socket = LAAClarifyFixtureSocket()
    func makeSocket(request: URLRequest, onOpen: @escaping (any HermesWebSocket) -> Void, onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void) -> any HermesWebSocket {
        Task { @MainActor in onOpen(self.socket) }
        return socket
    }
    func invalidate() {}
}
#endif
