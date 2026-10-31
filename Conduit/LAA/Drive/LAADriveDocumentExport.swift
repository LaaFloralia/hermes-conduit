#if LAA_BUILD
import Foundation

struct LAADrivePDFExport {
    let data: Data
    let version: String
}

enum LAADrivePDFExportError: Error, Equatable {
    case tooLarge, versionChanged
}

private struct LAADrivePDFErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String?; let message: String?; let retryable: Bool? }
    let error: Detail
    let requestId: String?
}

extension LAABridgeClient {
    /// PDF export is a bounded, authenticated 200 response, not a media Range.
    /// The existing Bridge session is ephemeral and refuses redirects.
    func driveExportPDF(id: String, credentials: LAABridgeCredentials,
                        expectedVersion: String? = nil) async throws -> LAADrivePDFExport {
        let maximum = 10_000_000
        let path = try LAADrivePaths.metadata(id) + "/export?mimeType=application%2Fpdf"
        guard expectedVersion.map(Self.validDriveVersion) ?? true,
              let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL,
              url.scheme == credentials.baseURL.scheme, url.host == credentials.baseURL.host,
              url.port == credentials.baseURL.port else { throw LAABridgeError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        if let expectedVersion { request.setValue(expectedVersion, forHTTPHeaderField: "x-laa-drive-version") }
        do {
            let (bytes, response) = try await rangeSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw LAABridgeError.invalidResponse }
            guard http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < 8192 else { break }
                    body.append(byte)
                }
                let envelope = try? JSONDecoder().decode(LAADrivePDFErrorEnvelope.self, from: body)
                throw LAABridgeHTTPError(status: http.statusCode, code: envelope?.error.code,
                                         message: envelope?.error.message, retryable: envelope?.error.retryable,
                                         details: nil, requestId: envelope?.requestId, currentETag: nil)
            }
            guard http.mimeType?.lowercased() == "application/pdf",
                  let version = http.value(forHTTPHeaderField: "x-laa-drive-version"),
                  Self.validDriveVersion(version) else { throw LAABridgeError.invalidResponse }
            if let expectedVersion, version != expectedVersion { throw LAADrivePDFExportError.versionChanged }
            var declaredLength: Int?
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(length) else { throw LAABridgeError.invalidResponse }
                guard parsed <= maximum else { throw LAADrivePDFExportError.tooLarge }
                declaredLength = parsed
            }
            var data = Data()
            if let declaredLength { data.reserveCapacity(declaredLength) }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximum else { throw LAADrivePDFExportError.tooLarge }
                data.append(byte)
            }
            guard declaredLength == nil || declaredLength == data.count,
                  data.starts(with: Data("%PDF-".utf8)) else { throw LAABridgeError.invalidResponse }
            return LAADrivePDFExport(data: data, version: version)
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

    private static func validDriveVersion(_ version: String) -> Bool {
        (1...30).contains(version.utf8.count) && version.utf8.allSatisfy { (48...57).contains($0) }
    }
}
#endif
