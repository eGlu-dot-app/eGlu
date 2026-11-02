import PadCore

extension Session {
    /// What both apps do after a change to the settings: saved, every page
    /// told, and the history, the blocking and iCloud brought in line. Each
    /// app's Session answers the changes only it has a use for.
    @discardableResult
    func preferencesChanged(from old: Preferences) -> Preferences.Changes {
        preferences.store(in: .standard, key: Session.preferencesKey)
        for page in pages.live.values { page.settingsChanged() }
        let changes = preferences.changes(from: old)
        if changes.contains(.historyRetention) { HistoryRecorder.shared.prune(always: true) }
        if changes.contains(.historySync) {
            if preferences.historySync { HistoryCloud.shared.started(backfill: true) } else { HistoryCloud.shared.switchedOff() }
        }
        if changes.contains(.contentBlocking) { ContentBlocker.shared.preferencesChanged() }
        if changes.contains(.iCloudSync), Session.canSync {
            if preferences.iCloudSync { Sync.shared.start(join: true) } else { Sync.shared.stop() }
        }
        WritingChecker.shared.preferencesChanged(preferences)
        #if os(macOS)
        if preferences.automaticPictureInPicture != old.automaticPictureInPicture {
            automaticPictureChanged()
        }
        ElsewhereChecker.shared.preferencesChanged()
        // WebKit's own spell checking steps aside while Harper checks, and
        // comes back as it was once Harper stops (WritingSpelling).
        if preferences.writing != old.writing {
            WritingSpelling.follow(writing: preferences.writing, views: pages.live.values.map(\.view))
        }
        #endif
        return changes
    }
}
