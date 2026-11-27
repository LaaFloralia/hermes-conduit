//
//  DashboardBackgroundRequests.swift
//  Conduit
//
//  Dashboard requests while the phone app is in the background (#378).
//
//  The ticket bridge normally runs every dashboard request inside its hidden
//  WebKit page, so the HttpOnly session cookie never leaves WebKit. WebKit
//  suspends that page once Conduit's phone screen leaves the foreground, and
//  never runs it when CarPlay launched the app without one. Ticket mints and
//  live-call starts then hung, and CarPlay kept trying to connect until the
//  phone app was opened. Without the page, the same request goes out through
//  URLSession carrying the page's cookies, the way the page's fetch would.
//

import Foundation
import WebKit

extension DashboardTicketBridge {
    /// A request whose JSON body is already encoded (a file upload's),
    /// always through URLSession: the page's path would copy the whole body
    /// into a script literal on the main actor and again inside WebKit.
    func requestEncodedJSON(
        path: String,
        method: String = "POST",
        encodedBody: Data,
        timeoutMilliseconds: Int = 12_000
    ) async throws -> [String: Any] {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        if let nativeOAuthSession {
            return try await nativeOAuthSession.requestJSON(
                path: path,
                method: method,
                encodedBody: encodedBody,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
        return try await requestJSONWithoutPage(
            path: path,
            method: method,
            encodedBody: encodedBody,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    /// The request the page's `fetch` would send, without the page: same
    /// path (resolved against the page's origin), method, JSON body and
    /// proxy headers, with the dashboard's cookies attached. Same error
    /// contract as `requestJSON`, except that having no cookies at all is
    /// `.notReady`: nothing proves the sign-in expired.
    func requestJSONWithoutPage(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        encodedBody: Data? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        guard let url = Self.pageRequestURL(path: path, baseURL: baseURL) else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("Could not encode dashboard request."))
        }
        let cookies = await cookiesForRequestsWithoutPage()
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        let cookieHeader = NativeAuthCookiePolicy.headerFields(for: cookies, url: url)
        guard !cookieHeader.isEmpty else { throw DashboardTicketBridgeError.notReady }

        var request = URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflareAccess)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(max(1_000, timeoutMilliseconds)) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method.uppercased() != "GET", method.uppercased() != "HEAD",
           let scheme = url.scheme, let host = url.host {
            // The page's fetch is same-origin, so the browser sends Origin
            // on everything but GET and HEAD.
            let port = url.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        if let encodedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedBody
        } else if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let result: (data: Data, response: URLResponse, oversized: Bool)
        do {
            if let loadWithoutPageForTesting {
                let (data, response) = try await loadWithoutPageForTesting(request)
                result = (data, response, false)
            } else {
                result = try await Self.load(
                    request,
                    deadline: .milliseconds(max(1_000, timeoutMilliseconds)),
                    maxResponseBytes: maxResponseBytes
                )
            }
        } catch let error as URLError {
            // A cancelled caller hears cancellation, as from the page path.
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            // What the page's fetch reports for a network failure or its
            // abort: status 0.
            throw DashboardTicketBridgeError.http(status: 0, detail: error.localizedDescription)
        }
        // invalidate() doesn't cancel this request: an answer that lands
        // after a dashboard switch is the old dashboard's, as on the page.
        guard !isInvalidated else {
            if let http = result.response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                throw DashboardTicketBridgeError.answeredAfterSwitch
            }
            throw DashboardTicketBridgeError.notReady
        }
        let (data, response, oversized) = result
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.")
        }
        let issued = NativeAuthCookiePolicy.acceptedCookies(from: http)
        if !issued.isEmpty, !isInvalidated {
            backgroundIssuedCookies = NativeAuthCookiePolicy.merged(backgroundIssuedCookies + issued)
            // The page picks the new cookies up when it runs again.
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for cookie in issued {
                store.setCookie(cookie, completionHandler: nil)
            }
        }
        if (300...399).contains(http.statusCode) {
            // Same-origin redirects are followed, as the page's fetch does.
            // One that comes back is to sign-in or another origin. Either
            // means the session is gone, as the page landing on sign-in
            // does: an auth proxy sends a request without its session to
            // its own sign-in host or the identity provider.
            if let dashboardURL = URL(string: baseURL),
               DashboardSignInRedirect.redirectIsSignIn(
                location: http.value(forHTTPHeaderField: "Location"),
                from: http.url ?? url,
                forDashboard: dashboardURL
               ) {
                throw DashboardTicketBridgeError.signInRequired
            }
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: AppLocalization.string("Dashboard request failed (\(String(http.statusCode))).")
            )
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            // Hermes' own 403 (a session write it refuses, a file it won't
            // serve) is a verdict on the request, not an expired sign-in (as
            // in the page's response handler).
            if http.statusCode == 403, !oversized,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = Self.errorDetail(object),
               !DashboardTicketBridgeError.meansSignIn(status: 403, hermesDetail: object["detail"] as? String)
                || SessionMutationIdentity.isRefusalDetail(detail) {
                throw DashboardTicketBridgeError.http(status: 403, detail: detail)
            }
            throw DashboardTicketBridgeError.signInRequired
        }
        guard !oversized else {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
        }
        let value = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200...299).contains(http.statusCode) else {
            let object = value as? [String: Any]
            let detail = Self.errorDetail(object)
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: detail ?? AppLocalization.string("Dashboard request failed (\(String(http.statusCode))).")
            )
        }
        // Shaped as the page's response: objects as they are, arrays under
        // `_array`, anything else under `value`.
        if let object = value as? [String: Any] { return object }
        if let array = value as? [Any] { return ["_array": array] }
        if data.isEmpty { return [:] }
        return ["value": value ?? String(decoding: data, as: UTF8.self)]
    }

    /// The error text a failed response carries, as the page reads it.
    private static func errorDetail(_ object: [String: Any]?) -> String? {
        (object?["error"] ?? object?["message"] ?? object?["detail"]) as? String
    }

    /// The response, or `URLError(.timedOut)` once `deadline` passes in
    /// total, as the page's AbortController does. A request's own timeout
    /// only limits the wait between bytes. The body is read as it arrives
    /// and no further than `maxResponseBytes` (`oversized` past it), so an
    /// oversized one is never held whole: this runs in the background and
    /// from CarPlay, where the memory limit is tightest.
    static func load(
        _ request: URLRequest,
        deadline: Duration,
        maxResponseBytes: Int,
        session: URLSession = DashboardBackgroundSession.shared
    ) async throws -> (data: Data, response: URLResponse, oversized: Bool) {
        #if DEBUG
        guard LAALabNetworkPolicy.current.allowsHermes(request.url) else { throw URLError(.unsupportedURL) }
        #endif
        return try await withThrowingTaskGroup(of: (data: Data, response: URLResponse, oversized: Bool).self) { group in
            group.addTask {
                // Chunk by chunk as URLSession delivers them, not byte by
                // byte (1.1 MB of Monet's catalog and history was a million
                // appends on the main path; D-25).
                try await DashboardBoundedLoad(maxResponseBytes: maxResponseBytes).run(request, session: session)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }

    /// Where the page's `fetch(path)` goes: `path` resolved against the
    /// page the bridge loads.
    nonisolated static func pageRequestURL(path: String, baseURL: String) -> URL? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let page = URL(string: "\(normalized)/api/status"),
              let url = URL(string: path, relativeTo: page)?.absoluteURL,
              ConnectionURLPolicy.originMatches(url, expected: page) else { return nil }
        return url
    }

    /// The dashboard's cookies from every store that holds them: the
    /// Keychain mirror, WebKit's own store (when it answers in time), the
    /// native sign-in jar (a silent re-sign-in lands there), and cookies
    /// issued to requests sent without the page.
    func cookiesForRequestsWithoutPage() async -> [HTTPCookie] {
        var cookies = DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID)
        if keepsWebKitCookies, let kept = keptWebKitCookies {
            cookies += kept
        } else {
            let generation = cookieReadGeneration
            if let webKit = await webKitCookies(timeout: .seconds(2)) {
                cookies += webKit
                // Kept only if nothing changed the store meanwhile; a read
                // that timed out is never kept.
                if keepsWebKitCookies, generation == cookieReadGeneration {
                    keptWebKitCookies = webKit
                }
            }
        }
        cookies += DashboardCookiePersistence.nativeCookieStorage(for: dashboardID).cookies ?? []
        cookies += backgroundIssuedCookies
        return Self.freshestCookies(cookies)
    }

    /// One copy of each cookie (name, domain, path): the one that expires
    /// last, since a newer sign-in or a renewed session runs longer. A
    /// session cookie (no expiry, the usual live dashboard session) counts
    /// as never expiring, so a dated copy never displaces it. Ties go to
    /// the later source.
    nonisolated static func freshestCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var order: [String] = []
        var chosen: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = [
                cookie.name,
                cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                cookie.path.isEmpty ? "/" : cookie.path,
            ].joined(separator: "\u{0}")
            guard let current = chosen[key] else {
                order.append(key)
                chosen[key] = cookie
                continue
            }
            let held = current.expiresDate ?? .distantFuture
            let offered = cookie.expiresDate ?? .distantFuture
            if offered < held { continue }
            chosen[key] = cookie
        }
        return order.compactMap { chosen[$0] }
    }

    /// WebKit's cookie store, or nil when it doesn't answer within
    /// `timeout` (its process may be suspended too).
    private func webKitCookies(timeout: Duration) async -> [HTTPCookie]? {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let once = DashboardCookieAnswer()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            store.getAllCookies { cookies in
                // A hop rather than assuming the main queue: a wrong-queue
                // callback must not trap in a car.
                Task { @MainActor in once.resume(cookies) }
            }
            once.timeout = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }
}

/// One response read in URLSession's own chunks, stopped as soon as it
/// passes `maxResponseBytes` (or announces a length past it, before any of
/// the body is held). Redirects stay with the session's delegate: this task
/// delegate implements only the data callbacks.
final class DashboardBoundedLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Result = (data: Data, response: URLResponse, oversized: Bool)
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<Result, Error>?
    private var outcome: Swift.Result<Result, Error>?
    private var task: URLSessionDataTask?

    init(maxResponseBytes: Int) {
        limit = max(0, maxResponseBytes)
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> Result {
        let task = session.dataTask(with: request)
        task.delegate = self
        lock.withLock { self.task = task }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let settled: Swift.Result<Result, Error>? = lock.withLock {
                    if outcome == nil { self.continuation = continuation }
                    return outcome
                }
                if let settled {
                    continuation.resume(with: settled)
                    return
                }
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        let waiting: CheckedContinuation<Result, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > limit {
            finish(.success((Data(), response, true)))
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over: Result? = lock.withLock {
            guard outcome == nil, let response else { return nil }
            let room = limit - data.count
            guard chunk.count > room else {
                data.append(chunk)
                return nil
            }
            // The rest isn't wanted: keep up to the limit and stop the download.
            data.append(chunk.prefix(max(0, room)))
            return (data, response, true)
        }
        if let over {
            finish(.success(over))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result: Result? = lock.withLock { response.map { (data, $0, false) } }
        if let result {
            finish(.success(result))
        } else if let response = task.response {
            finish(.success((Data(), response, false)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }
}

/// Resumes a cookie read exactly once: with the cookies, or nil on timeout.
@MainActor
private final class DashboardCookieAnswer {
    var continuation: CheckedContinuation<[HTTPCookie]?, Never>?
    var timeout: Task<Void, Never>?

    func resume(_ cookies: [HTTPCookie]?) {
        continuation?.resume(returning: cookies)
        continuation = nil
        timeout?.cancel()
        timeout = nil
    }
}

/// The URLSession for requests sent without the page. Cookies are set by
/// hand from the dashboard's own stores, so the session keeps none.
/// Same-origin redirects are followed with the same headers, as the page's
/// fetch follows them; a redirect to sign-in or another origin comes back
/// as the response.
enum DashboardBackgroundSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(DashboardBackgroundSession.redirect(
                from: task.originalRequest,
                to: request
            ))
        }
    }

    /// The redirect to follow, carrying the original request's headers
    /// (its cookies and proxy headers), or nil to return the redirect as
    /// the response: one to sign-in or to another origin.
    static func redirect(from original: URLRequest?, to proposed: URLRequest) -> URLRequest? {
        guard let original, let source = original.url, let destination = proposed.url,
              ConnectionURLPolicy.isAllowedTransport(destination),
              ConnectionURLPolicy.originMatches(destination, expected: source),
              !DashboardSignInRedirect.isSignInPath(destination.path) else { return nil }
        var followed = proposed
        for (name, value) in original.allHTTPHeaderFields ?? [:]
            where followed.value(forHTTPHeaderField: name) == nil {
            followed.setValue(value, forHTTPHeaderField: name)
        }
        return followed
    }
}
