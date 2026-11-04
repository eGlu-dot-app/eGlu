import Foundation

/// Download activity survives a window closing and a later app launch.
public struct DownloadRecord: Codable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case downloading, finished, failed, cancelled }
    public let id: UUID
    public var name: String
    public var source: URL?
    public var space: UUID
    public var method: String
    public var file: URL?
    public var fraction: Double?
    public var phase: Phase
    public var problem: String?
    public var resumeData: Data?
    public var exported = false
    public let created: Date
    /// Stable numeric id used by browser extensions; older activity is assigned one on demand.
    public var browserID: Int?
    public var bytesReceived: Int64?
    public var totalBytes: Int64?
    public var extensionInitiated: Bool?

    public init(id: UUID = UUID(), name: String, source: URL?, space: UUID, method: String = "GET") {
        self.id = id; self.name = name; self.source = source; self.space = space; self.method = method
        self.phase = .downloading; self.created = Date()
    }
    public var finished: Bool { phase == .finished }
    public var failed: Bool { phase == .failed || phase == .cancelled }
    public var canRestart: Bool { method.uppercased() == "GET" && ["https", "http"].contains(source?.scheme?.lowercased() ?? "") }
    public var canResume: Bool { resumeData?.isEmpty == false }

    public func recovered(fileExists: (URL) -> Bool) -> Self {
        var copy = self
        if phase == .downloading {
            copy.phase = .failed
            copy.problem = BrowserText.localized("Interrupted when eGlu closed. Resume or try again.")
            copy.fraction = nil
        } else if phase == .finished, file.map(fileExists) != true {
            copy.phase = .failed
            copy.problem = BrowserText.localized("The downloaded file is no longer available. Try downloading it again.")
        }
        return copy
    }
}
