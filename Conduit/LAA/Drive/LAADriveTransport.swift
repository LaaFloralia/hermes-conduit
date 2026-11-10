#if LAA_BUILD
import Foundation
#if DEBUG
import UIKit
#endif

enum LAADrivePaths {
    static func metadata(_ id: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (5...2048).contains(id.utf8.count), id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LAABridgeError.invalidResponse
        }
        return "/v1/drive/files/\(id)"
    }
    static func content(_ id: String) throws -> String { try metadata(id) + "/content" }
    static func validVersion(_ value: String) -> Bool {
        (1...30).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum LAADriveRangeError: Error, Equatable {
    case rangeUnsupported, unsatisfiable, invalidRange, tooLarge, versionChanged
}

struct LAADriveRangeResponse {
    let data: Data
    let total: Int64
    let mimeType: String?
    let version: String?

    init(data: Data, total: Int64, mimeType: String?, version: String? = nil) {
        self.data = data; self.total = total; self.mimeType = mimeType; self.version = version
    }
}

private struct LAADriveErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String?; let message: String?; let retryable: Bool? }
    let error: Detail
    let requestId: String?
}

extension LAABridgeClient {
    /// Bound every request and inspect its headers before consuming bytes. In
    /// particular, a server ignoring Range must never trigger a whole download.
    func driveRange(path: String, credentials: LAABridgeCredentials, offset: Int64,
                    length: Int, expectedVersion: String? = nil,
                    timeout: TimeInterval? = nil) async throws -> LAADriveRangeResponse {
        guard offset >= 0, length > 0, length <= LAADriveContent.chunkSize,
              expectedVersion.map(LAADrivePaths.validVersion) ?? true,
              expectedVersion == nil || path.hasPrefix("/v1/drive/files/"),
              offset <= Int64.max - Int64(length - 1), (path.hasPrefix("/v1/drive/files/") || LAAStudioMedia.bridgePathIsValid(path)),
              let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL,
              url.scheme == credentials.baseURL.scheme, url.host == credentials.baseURL.host,
              url.port == credentials.baseURL.port else { throw LAABridgeError.invalidAddress }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout ?? 30
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        if let expectedVersion { request.setValue(expectedVersion, forHTTPHeaderField: "x-laa-drive-version") }
        do {
            let (bytes, response) = try await rangeSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw LAABridgeError.invalidResponse }
            if http.statusCode == 416 { throw LAADriveRangeError.unsatisfiable }
            if http.statusCode == 200 { throw LAADriveRangeError.rangeUnsupported }
            guard http.statusCode == 206 else {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < 8192 else { break }
                    body.append(byte)
                }
                let envelope = try? JSONDecoder().decode(LAADriveErrorEnvelope.self, from: body)
                throw LAABridgeHTTPError(status: http.statusCode, code: envelope?.error.code,
                                         message: envelope?.error.message, retryable: envelope?.error.retryable,
                                         details: nil, requestId: envelope?.requestId, currentETag: nil)
            }
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseDriveRange(header), range.start == offset,
                  range.end <= offset + Int64(length - 1), range.total > range.end else {
                throw LAADriveRangeError.invalidRange
            }
            let version = http.value(forHTTPHeaderField: "x-laa-drive-version")
            if let version, !LAADrivePaths.validVersion(version) { throw LAADriveRangeError.invalidRange }
            if let expectedVersion, version != expectedVersion { throw LAADriveRangeError.versionChanged }
            let expected = Int(range.end - range.start + 1)
            var data = Data(capacity: expected)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < expected else { throw LAADriveRangeError.invalidRange }
                data.append(byte)
            }
            guard data.count == expected else { throw LAADriveRangeError.invalidRange }
            return .init(data: data, total: range.total, mimeType: http.mimeType, version: version)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: throw LAABridgeError.tlsFailed
            default: throw LAABridgeError.networkUnreachable
            }
        }
    }

    static func parseDriveRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let halves = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              let total = Int64(halves[1]), start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}

enum LAADriveContent {
    static let chunkSize = 512 * 1024
    // Images and PDFs are materialized for UIKit/PDFKit; media is never subject to this limit.
    static let previewLimit: Int64 = 64 * 1024 * 1024

    @MainActor static func range(_ item: LAADriveItem, offset: Int64, length: Int,
                                 bridge: LAABridgeSession, expectedVersion: String? = nil) async throws -> LAADriveRangeResponse {
        #if DEBUG
        if LAADriveData.fixture != nil {
            let directory = Bundle.main.bundleURL.appendingPathComponent("staff/monet")
            let data: Data
            if item.id == "video1", let file = try? Data(contentsOf: directory.appendingPathComponent("monet-idle-512.mov")) {
                data = file
            } else if item.id == "image1", let file = try? Data(contentsOf: directory.appendingPathComponent("monet-avatar-512.png")) {
                data = file
            } else if item.isPDF {
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
                data = renderer.pdfData { context in
                    context.beginPage()
                    ("Sample PDF" as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
                }
            } else { throw LAABridgeError.unavailable }
            guard offset < data.count else { throw LAADriveRangeError.unsatisfiable }
            let end = min(Int(offset) + length, data.count)
            return .init(data: data.subdata(in: Int(offset)..<end), total: Int64(data.count), mimeType: item.mimeType,
                         version: item.version ?? expectedVersion)
        }
        #endif
        return try await bridge.driveRange(path: LAADrivePaths.content(item.id), offset: offset, length: length,
                                           expectedVersion: expectedVersion)
    }

    @MainActor static func preview(_ item: LAADriveItem, bridge: LAABridgeSession) async throws -> Data {
        var data = Data()
        var total: Int64?
        var version = item.version
        repeat {
            let part = try await range(item, offset: Int64(data.count), length: chunkSize, bridge: bridge,
                                       expectedVersion: version)
            guard part.total <= previewLimit, total == nil || total == part.total else { throw LAADriveRangeError.tooLarge }
            if let received = part.version {
                guard version == nil || version == received else { throw LAADriveRangeError.versionChanged }
                version = received
            } else if version != nil { throw LAADriveRangeError.versionChanged }
            total = part.total
            data.append(part.data)
        } while Int64(data.count) < (total ?? 0)
        return data
    }
}
#endif
