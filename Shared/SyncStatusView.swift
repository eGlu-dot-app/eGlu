import PadCore
import SwiftUI

/// Status remains visible while disconnected. The date is a historical server
/// confirmation, not a claim that a newly enabled or offline device is current.
struct SyncStatusView: View {
    @ObservedObject private var sync = Sync.shared
    @State private var announcements = SyncResultAnnouncements()

    private var title: String {
        switch sync.status.phase {
        case .off: return "Sync is off"
        case .checkingAccount: return "Checking iCloud account"
        case .syncing: return "Syncing with iCloud"
        case .retrying: return "Retrying iCloud sync"
        case .completed: return "Sync completed"
        case .waiting(let reason):
            switch reason {
            case .connection: return "Waiting for a connection"
            case .service: return "Waiting for iCloud to retry"
            case .account: return "Waiting for an available Apple Account"
            case .pendingChanges: return "Changes are waiting to sync"
            case .confirmation: return "Waiting for iCloud confirmation"
            case .error: return "Sync could not complete. Retry when iCloud is available."
            }
        }
    }

    private var working: Bool {
        switch sync.status.phase {
        case .checkingAccount, .syncing, .retrying: return true
        default: return false
        }
    }

    private var canRetry: Bool {
        if case .waiting = sync.status.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if working { ProgressView().controlSize(.small) }
                Text(LocalizedStringKey(title)).font(.subheadline)
            }
            if let confirmed = sync.status.lastSuccessfulSync {
                LabeledContent("Last confirmed sync", value: confirmed.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No sync has been confirmed yet.").font(.footnote).foregroundStyle(.secondary)
            }
            if canRetry { Button("Retry Sync") { sync.retrySync() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("syncStatus")
        .onChange(of: sync.status.phase) { _, phase in
            guard announcements.accepts(phase) else { return }
            AccessibilityNotification.Announcement(BrowserText.localized(title)).post()
        }
    }
}
