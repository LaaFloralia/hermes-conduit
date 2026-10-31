#if LAA_BUILD
import Foundation

struct LAAPersonalUploadMetadata: Codable {
    let viewerId: String
    let filename: String
    let contentType: String
    let size: Int
    let sha256: String
}

private struct LAAPersonalUploadEnvelope: Decodable {
    let data: LAAPersonalOperationResponse
    let requestId: String
}
private struct LAAPersonalUploadFailure: Decodable {
    struct Detail: Decodable { let code: String?; let message: String?; let retryable: Bool?; let details: LAABridgeJSONValue? }
    let error: Detail
    let requestId: String?
}

extension LAABridgeClient {
    func uploadPersonalTaskFile(path: String, file: URL, metadata: LAAPersonalUploadMetadata,
                                credentials: LAABridgeCredentials, key: LAABridgeIdempotencyKey) async throws -> LAABridgeResponse<LAAPersonalOperationResponse> {
        guard path.hasPrefix("/v1/personal-tasks/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL,
              url.host == credentials.baseURL.host, url.scheme == credentials.baseURL.scheme,
              url.port == credentials.baseURL.port, file.isFileURL,
              let name = metadata.filename.data(using: .utf8) else { throw LAABridgeError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(key.value, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(metadata.viewerId, forHTTPHeaderField: "X-Linear-Viewer-Id")
        request.setValue(name.base64EncodedString(), forHTTPHeaderField: "X-Linear-File-Name")
        request.setValue(metadata.sha256, forHTTPHeaderField: "X-Linear-Content-Sha256")
        request.setValue(metadata.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(metadata.size), forHTTPHeaderField: "Content-Length")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await rangeSession.upload(for: request, fromFile: file) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as URLError where failure.code == .cancelled { throw CancellationError() }
        catch { throw LAABridgeError.networkUnreachable }
        guard let http = response as? HTTPURLResponse else { throw LAABridgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(LAAPersonalUploadFailure.self, from: data)
            throw LAABridgeHTTPError(status: http.statusCode, code: envelope?.error.code,
                message: envelope?.error.message, retryable: envelope?.error.retryable,
                details: envelope?.error.details, requestId: envelope?.requestId, currentETag: nil)
        }
        guard let envelope = try? JSONDecoder().decode(LAAPersonalUploadEnvelope.self, from: data) else { throw LAABridgeError.invalidResponse }
        return LAABridgeResponse(data: envelope.data, requestId: envelope.requestId, status: http.statusCode, etag: nil)
    }
}
#endif
