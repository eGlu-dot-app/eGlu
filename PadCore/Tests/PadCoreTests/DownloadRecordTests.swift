import Foundation
import Testing
@testable import PadCore

struct DownloadRecordTests {
    @Test func oldActivityLoadsWithoutExtensionFields() throws {
        let item = DownloadRecord(name: "legacy.txt", source: nil, space: UUID())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        for key in ["browserID", "bytesReceived", "totalBytes", "extensionInitiated"] { json[key] = nil }
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.id == item.id)
        #expect(restored.browserID == nil)
        #expect(restored.extensionInitiated == nil)
    }
    @Test func interruptedActivitySurvivesAStoredRoundTrip() throws {
        var item = DownloadRecord(name: "export.zip", source: URL(string: "https://example.com/export"), space: UUID())
        item.resumeData = Data([1, 2, 3])
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(item)).recovered { _ in false }
        #expect(restored.id == item.id)
        #expect(restored.phase == .failed)
        #expect(restored.canResume)
        #expect(restored.space == item.space)
    }
    @Test func completedFilesAreRetainedAfterCancellingAnExportPicker() {
        var item = DownloadRecord(name: "export.zip", source: nil, space: UUID())
        item.phase = .finished; item.file = URL(fileURLWithPath: "/synthetic/export.zip")
        #expect(item.recovered { _ in true }.phase == .finished)
        #expect(item.recovered { _ in false }.phase == .failed)
        #expect(item.file != nil)
    }
    @Test func postRequestsAreNeverAutomaticallyReplayed() {
        let item = DownloadRecord(name: "statement.pdf", source: URL(string: "https://example.com/export"), space: UUID(), method: "POST")
        #expect(!item.canRestart)
        #expect(!item.canResume)
    }
}
