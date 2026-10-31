import Foundation

private func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

private func expectError<T: Error & Equatable>(_ expected: T, _ run: () async throws -> Void) async {
    do { try await run(); fatalError("expected \(expected)") }
    catch let error as T { expect(error == expected, "expected \(expected), got \(error)") }
    catch { fatalError("unexpected error: \(error)") }
}

@main private struct PDFExportFixture {
    static func main() async throws {
        let credentials = LAABridgeCredentials(baseURL: URL(string: CommandLine.arguments[1])!,
                                               deviceID: "fixture", token: "fixture-token")
        let client = LAABridgeClient()
        let pdf = try await client.driveExportPDF(id: "file_1", credentials: credentials, expectedVersion: "2")
        expect(pdf.version == "2" && pdf.data.starts(with: Data("%PDF-".utf8)), "valid PDF and version")
        let withoutExpected = try await client.driveExportPDF(id: "file_other", credentials: credentials)
        expect(withoutExpected.version == "2", "response version required even without precondition")
        await expectError(LAABridgeError.invalidResponse) {
            _ = try await client.driveExportPDF(id: "../etc", credentials: credentials)
        }
        await expectError(LAABridgeError.invalidResponse) {
            _ = try await client.driveExportPDF(id: "file_1", credentials: credentials, expectedVersion: "2\r\nHeader: bad")
        }
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveExportPDF(id: "file_bad", credentials: credentials) }
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveExportPDF(id: "file_wrongmime", credentials: credentials) }
        await expectError(LAABridgeError.invalidResponse) { _ = try await client.driveExportPDF(id: "file_nover", credentials: credentials) }
        await expectError(LAADrivePDFExportError.versionChanged) {
            _ = try await client.driveExportPDF(id: "file_changed", credentials: credentials, expectedVersion: "2")
        }
        await expectError(LAADrivePDFExportError.tooLarge) { _ = try await client.driveExportPDF(id: "file_big", credentials: credentials) }
        do {
            _ = try await client.driveExportPDF(id: "file_denied", credentials: credentials)
            fatalError("expected 403")
        } catch let error as LAABridgeHTTPError {
            expect(error.status == 403 && error.code == "download_forbidden", "HTTP error code preserved")
        }
        let slow = Task { try await client.driveExportPDF(id: "file_slow", credentials: credentials) }
        try await Task.sleep(for: .milliseconds(200))
        slow.cancel()
        do { _ = try await slow.value; fatalError("expected cancellation") } catch is CancellationError { }
        print("Drive PDF client fixture passed")
    }
}
