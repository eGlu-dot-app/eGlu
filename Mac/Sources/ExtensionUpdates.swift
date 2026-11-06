import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

/// Updates from the Chrome Web Store, and extensions loaded from a folder
/// (Docs/ExtensionsDesign.md, section 3).
extension Extensions {
    // MARK: Updates

    static let checksKey = "extensionUpdates"

    /// Whether the daily check is on: Settings › Extensions, on unless turned off.
    static var checksForUpdates: Bool {
        get { UserDefaults.standard.object(forKey: checksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: checksKey) }
    }

    private static let checkedKey = "extensionsChecked"

    /// When the store was last asked.
    static var lastChecked: Date? { UserDefaults.standard.object(forKey: checkedKey) as? Date }

    /// Asked every hour whether a day's check is due (20 hours since the
    /// last), so an app left open for days keeps checking. (Search)
    func startUpdates() -> Timer {
        let clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.checkForUpdates() } }
        }
        clock.tolerance = 5 * 60
        Task { await checkForUpdates() }
        return clock
    }

    private static let declinedUpdatesKey = "extensionDeclinedUpdates"

    /// Explicit checks retry a declined version. Automatic checks leave that
    /// choice alone until the store offers a different version.
    @discardableResult
    func checkForUpdates(now: Bool = false, host: NSWindow? = nil) async -> ExtensionUpdateReport {
        guard now || Self.checksForUpdates else { return ExtensionUpdateReport(status: .disabled) }
        guard now || Date().timeIntervalSince(Self.lastChecked ?? .distantPast) > 20 * 60 * 60 else { return ExtensionUpdateReport(status: .notDue) }
        guard !checkingUpdates else { return ExtensionUpdateReport(status: .busy) }
        checkingUpdates = true
        defer { checkingUpdates = false }
        let original = installed.filter { $0.source == .store }
        let items = original.compactMap { item in ExtensionVersion(item.version).map { (id: item.id, version: $0) } }
        guard !items.isEmpty else { return ExtensionUpdateReport(status: .empty) }
        let owner = host ?? (now ? NSApp.keyWindow : nil)
        let urls = ExtensionStore.updateCheckURLs(for: items)
        var replies: [String: ExtensionUpdate] = [:]
        var answered = 0
        for url in urls {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            answered += 1
            for update in ExtensionUpdateReply.parse(data) { replies[update.id] = update }
        }
        var report = ExtensionUpdateReport()
        for item in original {
            guard let update = replies[item.id] else {
                report.entries.append(.init(id: item.id, name: item.name, outcome: .failed,
                                            detail: String(localized: "The store did not answer for this extension. Check your connection and try again.")))
                continue
            }
            switch update.status {
            case .current:
                report.entries.append(.init(id: item.id, name: item.name, outcome: .current))
            case .refused(let reason):
                report.entries.append(.init(id: item.id, name: item.name, outcome: .failed, detail: String(localized: "The store could not supply this extension: \(reason).")))
            case .newer:
                report.entries.append(await apply(update, retryDeclined: now, host: owner))
            }
        }
        if answered == urls.count && report.entries.allSatisfy({ $0.outcome != .failed }) {
            UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        }
        updateReport = report
        return report
    }

    private func apply(_ update: ExtensionUpdate, retryDeclined: Bool, host: NSWindow?) async -> ExtensionUpdateReport.Entry {
        let item = installed.first { $0.id == update.id && $0.source == .store }
        let name = item?.name ?? update.id
        let result = { (outcome: ExtensionUpdateReport.Outcome, detail: String?) in
            ExtensionUpdateReport.Entry(id: update.id, name: name, outcome: outcome, detail: detail)
        }
        guard let item, let current = ExtensionVersion(item.version), let offered = update.version else {
            return result(.deferred, String(localized: "The installed extension changed during the check. Check again."))
        }
        guard offered > current else { return result(.current, nil) }
        var declined = UserDefaults.standard.dictionary(forKey: Self.declinedUpdatesKey) as? [String: String] ?? [:]
        if !retryDeclined, declined[item.id] == offered.description {
            return result(.declined, String(localized: "Version \(offered.description) was declined. Checking for updates again lets you review it."))
        }
        do {
            let crx = try await download(item.id, from: update.package)
            let (archive, manifest, version) = try installExecution.verifyUpdate(crx, id: item.id, size: update.size,
                                                                            sha256: update.sha256, version: offered.description)
            guard installed.first(where: { $0.id == item.id }) == item else { return result(.deferred, String(localized: "Its settings changed while the update downloaded. Check again.")) }
            let wants = manifest.grants
            let had = item.granted ?? []
            if !Set(wants).isSubset(of: Set(had)) {
                guard let owner = host ?? Session.shared.frontWindow?.window, owner.isVisible else {
                    return result(.deferred, String(localized: "Open Extensions in Settings to review the additional access, then check for updates again."))
                }
                guard await askToUpdate(item, version: version, wanting: Set(wants).subtracting(had).sorted(), host: owner) else {
                    declined[item.id] = version
                    UserDefaults.standard.set(declined, forKey: Self.declinedUpdatesKey)
                    return result(.declined, String(localized: "Version \(version) was declined. The installed version keeps working."))
                }
                guard installed.first(where: { $0.id == item.id }) == item else { return result(.deferred, String(localized: "The extension changed while you reviewed its access. Check again.")) }
            }
            let name = manifest.name(fallback: item.name)
            try await trial(archive, id: item.id)
            guard installed.first(where: { $0.id == item.id }) == item else { return result(.deferred, String(localized: "The extension changed during verification. Check again.")) }
            let installation = try keep(archive, id: item.id, name: name, version: version, source: .store,
                                        access: item.siteAccess, spaces: item.spaces, granted: wants)
            guard await installation.value else { return result(.failed, String(localized: "The new version could not start. eGlu retained the previous version; report the problem or try again later.")) }
            declined[item.id] = nil
            UserDefaults.standard.set(declined, forKey: Self.declinedUpdatesKey)
            return result(.updated, nil)
        } catch {
            return result(.failed, error.localizedDescription + " " + String(localized: "The installed version was retained. Try again or report the problem."))
        }
    }

    /// A new package for one installed, put in its place: its manifest read,
    /// tried (`trial`), then kept with the item's site access, spaces and
    /// source. False, leaving the version there is in place, when the item
    /// was removed, turned off or changed meanwhile. A store update has its
    /// own steps (`apply`), which say why one didn't happen.
    @discardableResult
    private func replace(_ item: Installed, with archive: Data, folder: String? = nil) async throws -> Bool {
        let manifest = try installExecution.readArchive(archive)
        let version = try manifest.checkedVersion()
        guard installed.first(where: { $0.id == item.id }) == item else { return false }
        // One that won't start leaves the version there is in place.
        try await trial(archive, id: item.id)
        guard installed.first(where: { $0.id == item.id }) == item else { return false }
        try keep(archive, id: item.id, name: manifest.name(fallback: item.name),
                 version: version, source: item.source, access: item.siteAccess, spaces: item.spaces,
                 granted: manifest.grants, folder: folder)
        return true
    }

    /// A new version prepared in a folder of its own and started in a
    /// controller that keeps nothing (ExtensionTrial), before it takes the
    /// old one's place; nothing of it is left behind either way.
    func trial(_ archive: Data, id: String) async throws {
        try await installExecution.trial(archive, id: id)
    }

    /// A reloaded folder that wants more: asked in a sheet, as an update is.
    private func askToReload(_ item: Installed, wanting more: [String], host: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Reload \(item.name) with more access?")
        alert.informativeText = String(localized: "Additional access:") + "\n" + ExtensionAccessDescription.lines(for: more).map { "• " + $0 }.joined(separator: "\n")
            + "\n\n" + String(localized: "Don't Reload keeps the version loaded now.")
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Don't Reload"))
        return await present(alert, in: nil, host: host) == .alertFirstButtonReturn
    }

    /// An update that wants more: asked in a sheet, as at install.
    func askToUpdate(_ item: Installed, version: String, wanting more: [String], host: NSWindow) async -> Bool {
        let spaces = item.spaces.compactMap { Session.shared.workspace.space($0)?.name }
        let note = [
            spaces.isEmpty ? String(localized: "It is on in no space.")
                           : String(localized: "On in \(ListFormatter.localizedString(byJoining: spaces)). New spaces don't get it automatically."),
            String(localized: "Not Now keeps \(item.version) and stops asking about this version. Check Again in Settings lets you review it later."),
        ].joined(separator: " ")
        let summary = ExtensionAccessSummary(grants: more)
        let image = icon(of: item.id)
        return await ask(in: nil, host: host) { answer in
            ExtensionAskSheet(image: image, title: String(localized: "Update \u{201C}\(item.name)\u{201D} to \(version)?"),
                              subtitle: AnyView(Label("The new version asks for more access", systemImage: "arrow.up.circle")),
                              note: note, cancel: String(localized: "Not Now"), confirm: String(localized: "Update"),
                              answer: { answer($0) }) {
                ExtensionAccessGroups(summary: summary, everything: true)
            }
        } == true
    }

    // MARK: Loading from a folder

    /// Load Unpacked: a developer's folder, copied in as it is now. Its id
    /// is its path's, as Chrome makes one, so Reload finds it again and it
    /// can never be, or take the place of, a store extension.
    func loadUnpacked(in window: WindowModel?, host: NSWindow? = nil) {
        let host = host ?? window?.window ?? NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose an extension's folder: the one with its manifest.json.")
        Task {
            guard await choose(panel, host: host) == .OK, let folder = panel.url else { return }
            do {
                // Its real path, links resolved, as Chrome makes the id from.
                let snapshot = try await installExecution.snapshot(folder)
                try await offer(snapshot.archive, id: snapshot.id, source: .unpacked, in: window, folder: snapshot.path, host: host)
            } catch {
                tell(error, in: window, host: host)
            }
        }
    }

    /// The folder read again, for an unpacked extension; in its place, with
    /// its data and where it is on.
    func reload(_ id: String, host: NSWindow? = nil) {
        let host = host ?? NSApp.keyWindow
        guard let item = installed.first(where: { $0.id == id }), item.source == .unpacked, let path = item.folder else { return }
        Task {
            do {
                let archive = try await Self.zipped(URL(fileURLWithPath: path, isDirectory: true))
                // A folder that now asks for more is asked about first, as an
                // update is; no leaves the version loaded now. (Search)
                let more = Set(try installExecution.readArchive(archive).grants).subtracting(item.granted ?? []).sorted()
                if !more.isEmpty {
                    guard let owner = host ?? Session.shared.frontWindow?.window, await askToReload(item, wanting: more, host: owner) else { return }
                }
                try await replace(item, with: archive, folder: path)
            } catch {
                tell(error, in: nil, host: host, title: String(localized: "The extension could not be reloaded."))
            }
        }
    }
}
