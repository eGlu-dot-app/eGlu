import PadCore
import SwiftUI

/// Import recovery stays beside the result instead of ending at an OK button.
struct BookmarkImportStatusView: View {
    @ObservedObject var session: Session
    @Binding var outcome: BookmarkImportOutcome?
    let chooseFile: () -> Void
    var showFileChoice = true
    var showRecoveryActions = true
    @State private var destination: UUID?
    @State private var working = false

    var body: some View {
        if let result = outcome {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.title).font(.headline)
                Text(result.message).font(.subheadline).foregroundStyle(.secondary)
                if showRecoveryActions, let parsed = result.parsed {
                    Picker("Import into", selection: $destination) {
                        Text("Choose a Space").tag(UUID?.none)
                        ForEach(session.workspace.spaces) { space in Text(space.name).tag(Optional(space.id)) }
                    }
                    Button("Import into Selected Space") {
                        guard let destination else { return }
                        working = true
                        session.importBookmarks(parsed, into: destination) { next in
                            outcome = next
                            working = false
                            next.announceResult()
                        }
                    }
                    .disabled(destination == nil || working)
                } else if showRecoveryActions, result.needsSave {
                    Button("Retry Saving") {
                        working = true
                        session.retryBookmarkImport(result) { next in
                            outcome = next
                            working = false
                            next.announceResult()
                        }
                    }
                    .disabled(working)
                }
                if showFileChoice, result.canChooseFile || result.isComplete {
                    Button(result.isComplete ? "Import Another File…" : "Choose Another File…", action: chooseFile)
                        .disabled(working)
                }
                if working { ProgressView("Saving bookmarks") }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bookmarkImportResult")
        }
    }
}

extension BookmarkImportOutcome {
    /// Called once by the action's completion, never when a result card is
    /// redisplayed or its destination changes. A cancelled picker is silent.
    @MainActor
    func announceResult() {
        guard self != .cancelled else { return }
        AccessibilityNotification.Announcement(title + ". " + message).post()
    }
}
