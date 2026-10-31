#if LAA_BUILD
import Foundation

/// A bounded range transfer that receives network data in blocks, while still
/// checking the response before accepting bytes. The session is reused across
/// requests and never follows a redirect carrying the Bridge authorization.
enum LAADriveTransferError: Error, Equatable {
    case invalidRange
    case rangeUnsupported
    case unsatisfiable
}

struct LAADriveTransferResponse {
    let response: HTTPURLResponse
    let data: Data
    /// Present only for a validated 206 response.
    let total: Int64?
}

final class LAADriveRangeTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LAADriveRangeTransfer()
    static let maximumRangeBytes = 2 * 1024 * 1024

    private final class State {
        let offset: Int64
        let length: Int
        let continuation: CheckedContinuation<LAADriveTransferResponse, Error>
        var response: HTTPURLResponse?
        var total: Int64?
        var expected = 0
        var body = Data()
        var failure: Error?
        var truncatedErrorBody = false

        init(offset: Int64, length: Int, continuation: CheckedContinuation<LAADriveTransferResponse, Error>) {
            self.offset = offset
            self.length = length
            self.continuation = continuation
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var task: URLSessionTask?

        func attach(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func read(_ request: URLRequest, offset: Int64, length: Int) async throws -> LAADriveTransferResponse {
        guard offset >= 0, length > 0, length <= Self.maximumRangeBytes,
              offset <= Int64.max - Int64(length - 1) else {
            throw LAADriveTransferError.invalidRange
        }
        var request = request
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let cancellation = Cancellation()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = State(offset: offset, length: length, continuation: continuation)
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()
                cancellation.attach(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            states[dataTask.taskIdentifier]?.failure = LAADriveTransferError.invalidRange
            completionHandler(.cancel)
            return
        }
        state.response = http
        if http.statusCode == 200 {
            state.failure = LAADriveTransferError.rangeUnsupported
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 416 {
            state.failure = LAADriveTransferError.unsatisfiable
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 206 {
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseRange(header), range.start == state.offset,
                  range.end <= state.offset + Int64(state.length - 1) else {
                state.failure = LAADriveTransferError.invalidRange
                completionHandler(.cancel)
                return
            }
            let expected = Int(range.end - range.start + 1)
            if let declared = http.value(forHTTPHeaderField: "Content-Length"), Int(declared) != expected {
                state.failure = LAADriveTransferError.invalidRange
                completionHandler(.cancel)
                return
            }
            state.expected = expected
            state.total = range.total
            state.body.reserveCapacity(expected)
        } else {
            // Keep a small JSON error envelope for the existing error mapper.
            state.expected = 8192
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier] else { lock.unlock(); return }
        let remaining = state.expected - state.body.count
        if data.count > remaining {
            if state.response?.statusCode == 206 {
                state.failure = LAADriveTransferError.invalidRange
            } else {
                if remaining > 0 { state.body.append(data.prefix(remaining)) }
                state.truncatedErrorBody = true
            }
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
        } else if let error, !state.truncatedErrorBody {
            state.continuation.resume(throwing: error)
        } else if let response = state.response,
                  response.statusCode != 206 || state.body.count == state.expected {
            state.continuation.resume(returning: .init(response: response, data: state.body, total: state.total))
        } else {
            state.continuation.resume(throwing: LAADriveTransferError.invalidRange)
        }
    }

    private static func parseRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let halves = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              let total = Int64(halves[1]), start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}
#endif
