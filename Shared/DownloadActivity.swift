import Foundation
import os
import PadCore
import SwiftUI
import WebEngineCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class Downloads: NSObject, ObservableObject, WebDownloadDelegate {
    static let shared = Downloads()
    private static let log = Logger(subsystem: "net.taehee.safience", category: "Downloads")
    typealias Item = DownloadRecord
    @Published private(set) var items: [Item] = []
    @Published private(set) var storageProblem: String?
    private struct Running {
        let download: any WebDownload
        let item: UUID
        let page: ObjectIdentifier?
        var watch: NSKeyValueObservation?
    }
    private var running: [ObjectIdentifier: Running] = [:]
    private var retryViews: [UUID: any WebDownloadStarting] = [:]
    private var stopping: Set<UUID> = []
    private static var folder: URL { Session.folder.appendingPathComponent("Downloads", isDirectory: true) }
    private static var index: URL { folder.appendingPathComponent("activity.json") }

    private var activityStorage = DownloadActivityStorage(file: Downloads.index)
    private var removedActivity: Set<UUID> = []

    private override init() {
        super.init()
        restoreActivity(saving: false)
    }

    /// Retry never replaces the retained source until it has been read and merged successfully.
    func retryStorage() { restoreActivity(saving: true) }

    private func restoreActivity(saving: Bool) {
        switch activityStorage.load() {
        case .missing:
            storageProblem = nil
            if saving { persist() }
        case .loaded(let saved):
            let recovered = saved.map { $0.recovered { FileManager.default.fileExists(atPath: $0.path) } }
            items = DownloadActivityStorage.merge(recovered: recovered, current: items, excluding: removedActivity)
            storageProblem = nil
            if saving { persist() }
        case .unavailable(let failure):
            storageProblem = failure == .decode
                ? String(localized: "Saved download activity is damaged. Its original file and downloaded files are retained. New activity has not been saved. Retry after restoring the saved list.")
                : String(localized: "Saved download activity could not be read. Existing files are retained. New activity has not been saved. Restore access or available storage, then retry.")
        }
    }

    var activeCount: Int { items.filter { $0.phase == .downloading }.count }
    var active: Bool { activeCount > 0 }
    var fraction: Double {
        let known = items.filter { $0.phase == .downloading }.compactMap(\.fraction)
        return known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
    }
    func isDownloading(for page: Page) -> Bool { running.values.contains { $0.page == ObjectIdentifier(page) } }
    func adopt(_ download: any WebDownload, for page: Page) { adopt(download, from: page) }
    func adopt(_ download: any WebDownload, from page: Page) {
        let request = download.originalRequest
        let suggested = request?.url?.lastPathComponent ?? ""
        let item = Item(name: suggested.isEmpty ? String(localized: "Download") : suggested,
                        source: request?.url, space: page.space, method: request?.httpMethod ?? "GET")
        items.insert(item, at: 0)
        attach(download, item: item.id, page: ObjectIdentifier(page))
        persist()
    }

    private func attach(_ download: any WebDownload, item: UUID, page: ObjectIdentifier?) {
        download.delegate = self
        running[ObjectIdentifier(download)] = Running(download: download, item: item, page: page)
        let watch = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? min(1, max(0, progress.fractionCompleted)) : nil
            Task { @MainActor in self?.update(download) { $0.fraction = fraction } }
        }
        running[ObjectIdentifier(download)]?.watch = watch
    }
    private func update(_ download: any WebDownload, _ change: (inout Item) -> Void) {
        guard let id = running[ObjectIdentifier(download)]?.item, let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
    private func change(_ id: UUID, _ update: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        update(&items[index]); persist()
    }
    private func end(_ download: any WebDownload) {
        guard let ended = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        ended.watch?.invalidate()
        retryViews[ended.item] = nil
        persist()
    }
    private func persist() {
        guard activityStorage.canWrite else { return }
        do {
            try activityStorage.save(items)
            removedActivity = []
            storageProblem = nil
        } catch { storageProblem = String(localized: "Download activity has not been saved on this device. Existing files are retained. Check available storage and file access, then retry.") }
    }
    func clearFinished() {
        let previous = Set(items.map(\.id))
        #if canImport(UIKit)
        items.removeAll { $0.failed || $0.exported }
        #else
        items.removeAll { $0.phase != .downloading }
        #endif
        removedActivity.formUnion(previous.subtracting(items.map(\.id)))
        persist()
    }
    func exported(_ id: UUID) { change(id) { $0.exported = true } }

    func cancel(_ item: Item) {
        guard !stopping.contains(item.id), let active = running.values.first(where: { $0.item == item.id }) else { return }
        stopping.insert(item.id)
        change(item.id) { $0.problem = String(localized: "Stopping the download…") }
        active.download.cancel { [weak self] data in
            guard let self else { return }
            change(item.id) {
                $0.phase = .cancelled
                $0.problem = String(localized: "Cancelled. Resume if the server supports it, or try again.")
                $0.resumeData = data
                $0.fraction = nil
            }
            end(active.download)
            stopping.remove(item.id)
        }
    }

    func retry(_ item: Item) {
        guard !stopping.contains(item.id), let item = items.first(where: { $0.id == item.id }), item.phase != .downloading,
              item.canResume || item.canRestart else { return }
        guard Session.shared.workspace.space(item.space) != nil else {
            change(item.id) { $0.problem = String(localized: "The source space was removed. Open the source page in an existing space to download again.") }
            return
        }
        let starter = Self.retryStarter(space: item.space)
        retryViews[item.id] = starter
        change(item.id) { $0.phase = .downloading; $0.fraction = nil; $0.problem = nil }
        let started: @MainActor @Sendable (any WebDownload) -> Void = { [weak self] download in
            self?.attach(download, item: item.id, page: nil)
        }
        if let resume = item.resumeData, !resume.isEmpty {
            starter.resumeDownload(fromResumeData: resume, completionHandler: started)
        } else if let source = item.source {
            starter.startDownload(using: URLRequest(url: source), completionHandler: started)
        }
    }

    func download(_ download: any WebDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let id = running[ObjectIdentifier(download)]?.item else { return completionHandler(nil) }
        let destination: URL
        #if os(macOS)
        let overrides = [ProcessInfo.processInfo.environment["EGLU_DATA_ROOT"], Bundle.main.object(forInfoDictionaryKey: "EGLU_DATA_ROOT") as? String]
        if overrides.compactMap({ $0 }).contains(where: { $0.hasPrefix("/") }) {
            destination = Self.folder.appendingPathComponent("Files", isDirectory: true)
        } else {
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Self.folder
        }
        #else
        destination = Self.folder.appendingPathComponent("Files", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        #endif
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch {
            Self.log.error("No download folder: \(error.localizedDescription, privacy: .public)")
            update(download) { $0.phase = .failed; $0.problem = String(localized: "The file could not be saved. Check available storage and file access, then try again.") }
            persist(); completionHandler(nil); return
        }
        let held = Set(items.filter { $0.phase == .downloading }.compactMap { $0.file.map { DownloadName.key($0.standardizedFileURL.path) } })
        let name = DownloadName.free(for: suggestedFilename) { candidate in
            let path = destination.appendingPathComponent(candidate).standardizedFileURL.path
            return held.contains(DownloadName.key(path)) || FileManager.default.fileExists(atPath: path)
        }
        let file = destination.appendingPathComponent(name)
        update(download) { $0.name = name; $0.file = file }
        persist(); completionHandler(file)
    }
    func downloadDidFinish(_ download: any WebDownload) {
        update(download) { $0.phase = .finished; $0.fraction = 1; $0.problem = nil; $0.resumeData = nil }
        #if os(macOS)
        if let file = items.first(where: { $0.id == running[ObjectIdentifier(download)]?.item })?.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        #else
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Download finished. Open Downloads to save a copy to Files."))
        #endif
        end(download)
    }
    func download(_ download: any WebDownload, didFailWithError error: Error, resumeData: Data?) {
        if let id = running[ObjectIdentifier(download)]?.item, stopping.contains(id) { return }
        update(download) {
            if $0.phase != .cancelled {
                $0.phase = .failed
                let code = (error as NSError).code
                $0.problem = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(code)
                    ? String(localized: "The connection stopped. Check your connection, then Resume or Try Again.")
                    : String(localized: "The download stopped. Resume or try again; the source page may require you to sign in again.")
            }
            // A resume that failed with nothing new to resume from can't be
            // resumed again: Try Again then starts over rather than repeating it.
            $0.resumeData = resumeData
            $0.fraction = nil
        }
        end(download)
    }
}
