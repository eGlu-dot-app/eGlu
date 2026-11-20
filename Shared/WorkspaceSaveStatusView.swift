import PadCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(workspace: Workspace) throws { data = try WorkspaceFile.exportData(workspace) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// A local disk error remains visible until the latest revision is acknowledged.
/// Export copies workspace metadata; it never claims to save a website's draft.
struct WorkspaceSaveStatusView: View {
    /// Setup keeps its retry in the footer, but still offers backup export.
    var showsRetry = true
    @ObservedObject private var persistence = Session.shared.persistence
    @State private var backup: WorkspaceBackupDocument?
    @State private var exporting = false
    @State private var exportFailed = false

    var body: some View {
        Group {
            if let failure = persistence.state.failure {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Changes Haven't Been Saved on This Device", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(instruction(for: failure))
                        .font(.subheadline)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions }
                        VStack(alignment: .leading, spacing: 10) { actions }
                    }
                    if exportFailed {
                        Text("The backup wasn't exported. Choose another location and try again.")
                            .foregroundStyle(.red)
                    }
                    Text("A workspace backup contains spaces, tab addresses and bookmarks. Sign-ins and unsaved website content are not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.regularMaterial)
                .accessibilityIdentifier("workspaceSaveFailure")
            }
        }
        .fileExporter(isPresented: $exporting, document: backup, contentType: .json,
                      defaultFilename: String(localized: "eGlu Workspace Backup")) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { exportFailed = true }
        }
    }

    private var actions: some View {
        Group {
            if showsRetry {
                Button(persistence.isSaving ? "Retrying…" : "Retry Save") { Session.shared.retryWorkspaceSave() }
                    .disabled(persistence.isSaving)
            }
            Button("Export Workspace Backup") {
                do {
                    backup = try WorkspaceBackupDocument(workspace: Session.shared.workspace)
                    exportFailed = false
                    exporting = true
                } catch { exportFailed = true }
            }
        }
        .buttonStyle(.bordered)
    }

    private func instruction(for failure: WorkspaceSaveFailure) -> String {
        switch failure {
        case .outOfSpace: return String(localized: "Free some storage, then retry or export a workspace backup to another location.")
        case .permissionDenied: return String(localized: "Check that eGlu can write to its data folder, then retry or export a workspace backup.")
        case .sourceUnavailable: return String(localized: "The saved workspace cannot be updated. Export a backup before closing eGlu, then use workspace recovery.")
        case .writeFailed: return String(localized: "Check available storage, then retry or export a workspace backup before closing eGlu.")
        }
    }
}
