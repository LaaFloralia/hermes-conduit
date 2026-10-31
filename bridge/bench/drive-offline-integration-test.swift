import Foundation

@main
struct OfflineFixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let operations = LAADriveOfflineOperations(root: root.appendingPathComponent("store"),
                                                    shareFiles: LAADriveShareFiles(root: root.appendingPathComponent("shares")))
        let bridge = LAABridgeSession()
        let item = LAADriveItem(id: "file01", name: "Fixture", mimeType: "image/png", kind: "file", version: "1",
                                size: Int64(bridge.bytes.count), modifiedAt: nil, downloadable: true,
                                exportFormats: nil, thumbnailLink: nil, owners: nil)
        try await operations.save(item, bridge: bridge)
        let records = try await operations.records(bridge: bridge)
        precondition(records.count == 1 && records[0].version == "1")
        let online = try await operations.open(records[0], bridge: bridge)
        let bytes = try Data(contentsOf: online.url)
        precondition(online.checkedOnline && bytes == bridge.bytes)
        bridge.mode = .offline
        let offline = try await operations.open(records[0], bridge: bridge)
        precondition(offline.checkedOnline == false)
        bridge.mode = .denied
        do { _ = try await operations.open(records[0], bridge: bridge); fatalError("denial opened") }
        catch LAADriveOfflineError.forbidden { }
        let deniedRecords = try await operations.records(bridge: bridge)
        precondition(deniedRecords[0].access == .denied)
        bridge.mode = .offline
        do { _ = try await operations.open(records[0], bridge: bridge); fatalError("offline denial opened") }
        catch LAADriveOfflineError.forbidden { }
        bridge.mode = .online
        bridge.version = "2"
        let stale = try await operations.open(records[0], bridge: bridge)
        precondition(stale.record.access == .stale && stale.record.version == "1")
        bridge.mode = .missing
        do { _ = try await operations.open(records[0], bridge: bridge); fatalError("missing file opened") }
        catch LAADriveOfflineError.notFound { }
        bridge.mode = .online
        bridge.version = "1"
        let restored = try await operations.open(records[0], bridge: bridge)
        precondition(restored.record.access == .verified)

        let document = LAADriveItem(id: "doc001", name: "Document", mimeType: "application/vnd.google-apps.document",
                                    kind: "workspace_document", version: "1", size: nil, modifiedAt: nil,
                                    downloadable: true, exportFormats: ["application/pdf"], thumbnailLink: nil, owners: nil)
        try await operations.save(document, bridge: bridge)
        let withDocument = try await operations.records(bridge: bridge)
        let documentRecord = withDocument.first { $0.id == document.id }!
        let pdf = try await operations.open(documentRecord, bridge: bridge)
        let pdfData = try Data(contentsOf: pdf.url)
        precondition(pdf.record.sourceFormat == .workspacePDF && pdf.record.mimeType == "application/pdf")
        precondition(pdfData.starts(with: Data("%PDF-".utf8)))
        try await operations.remove(documentRecord, bridge: bridge)

        let unstable = LAADriveItem(id: "file02", name: "Changed", mimeType: "image/png", kind: "file", version: "1",
                                    size: Int64(bridge.bytes.count), modifiedAt: nil, downloadable: true,
                                    exportFormats: nil, thumbnailLink: nil, owners: nil)
        bridge.changeDuringRange = true
        do { try await operations.save(unstable, bridge: bridge); fatalError("changed file saved") }
        catch LAADriveOfflineError.versionChanged { }
        let afterChange = try await operations.records(bridge: bridge)
        precondition(afterChange.count == 1)
        bridge.changeDuringRange = false
        bridge.version = "1"
        bridge.deviceID = "other-pairing"
        bridge.revision += 1
        let otherRecords = try await operations.records(bridge: bridge)
        precondition(otherRecords.isEmpty)
        do { _ = try await operations.open(records[0], bridge: bridge); fatalError("different pairing opened") }
        catch LAADriveOfflineError.accessChanged { }
        bridge.deviceID = "fixture-pairing"
        bridge.revision += 1
        try await operations.remove(records[0], bridge: bridge)
        let afterRemoval = try await operations.records(bridge: bridge)
        precondition(afterRemoval.isEmpty)
        print("Offline integration fixture passed: file and PDF save, offline, denial, recovery, version change, pairing and removal")
    }
}
