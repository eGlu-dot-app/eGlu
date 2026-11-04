import AppKit
import Combine
import PadCore
import WebKit

@MainActor
final class ExtensionDownloads {
    static let shared = ExtensionDownloads()
    private var watching: AnyCancellable?
    private var previous: [UUID: DownloadRecord] = [:]

    private init() {
        Downloads.shared.assignBrowserIDs()
        previous = Dictionary(uniqueKeysWithValues: Downloads.shared.items.map { ($0.id, $0) })
        watching = Downloads.shared.$items.dropFirst().sink { [weak self] items in
            MainActor.assumeIsolated { self?.changed(items) }
        }
    }

    private func state(_ item: DownloadRecord) -> String {
        item.finished ? "complete" : item.phase == .downloading ? "in_progress" : "interrupted"
    }

    private func describe(_ item: DownloadRecord) -> [String: Any] {
        var json: [String: Any] = ["id": item.browserID ?? -1, "url": item.source?.absoluteString ?? "", "finalUrl": item.source?.absoluteString ?? "",
                                  "filename": item.file?.path ?? item.name, "state": state(item), "paused": false,
                                  "canResume": item.canResume, "exists": item.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                                  "bytesReceived": item.bytesReceived ?? 0, "totalBytes": item.totalBytes ?? -1,
                                  "fileSize": item.file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? -1,
                                  "startTime": ISO8601DateFormatter().string(from: item.created), "incognito": false, "danger": "safe", "mime": ""]
        if item.failed { json["error"] = item.phase == .cancelled ? "USER_CANCELED" : "SERVER_FAILED" }
        return json
    }

    private func changed(_ items: [DownloadRecord]) {
        let before = previous
        previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            guard let id = item.browserID else { continue }
            guard let old = before[item.id] else {
                ExtensionEvents.shared.send("downloads.onCreated", arguments: [describe(item)], permission: "downloads", in: item.space)
                continue
            }
            var delta: [String: Any] = ["id": id]
            if state(old) != state(item) { delta["state"] = ["previous": state(old), "current": state(item)] }
            if old.file != item.file { delta["filename"] = ["previous": old.file?.path ?? old.name, "current": item.file?.path ?? item.name] }
            if old.phase != item.phase, item.failed { delta["error"] = ["current": item.phase == .cancelled ? "USER_CANCELED" : "SERVER_FAILED"] }
            if delta.count > 1 { ExtensionEvents.shared.send("downloads.onChanged", arguments: [delta], permission: "downloads", in: item.space) }
        }
        let kept = Set(items.map(\.id))
        for item in before.values where !kept.contains(item.id) {
            if let id = item.browserID { ExtensionEvents.shared.send("downloads.onErased", arguments: [id], permission: "downloads", in: item.space) }
        }
    }

    private func search(_ query: [String: Any], in space: UUID) throws -> [DownloadRecord] {
        let allowed: Set<String> = ["id", "url", "filename", "state", "paused", "exists", "query", "startedAfter", "startedBefore", "limit", "orderBy"]
        guard Set(query.keys).isSubset(of: allowed) else { throw Extensions.Unanswered(why: "This browser cannot search downloads by this filter.") }
        let terms = query["query"] as? [String] ?? []
        let formatter = ISO8601DateFormatter()
        let from = (query["startedAfter"] as? String).flatMap(formatter.date(from:))
        let to = (query["startedBefore"] as? String).flatMap(formatter.date(from:))
        let order = query["orderBy"] as? [String] ?? ["-startTime"]
        guard order.allSatisfy({ ["startTime", "-startTime", "filename", "-filename", "id", "-id"].contains($0) }) else {
            throw Extensions.Unanswered(why: "This browser can sort downloads by start time, file name, or id.")
        }
        let limit = query["limit"] as? Int ?? 1000
        guard limit >= 0 else { throw Extensions.Unanswered(why: "Invalid download result limit.") }
        return Array(Downloads.shared.items.filter { item in
            guard item.space == space else { return false }
            let json = describe(item)
            for key in ["id", "url", "filename", "state", "paused", "exists"] where query[key] != nil {
                if !NSDictionary(dictionary: [key: query[key]!]).isEqual(to: [key: json[key] ?? NSNull()]) { return false }
            }
            if let from, item.created <= from { return false }
            if let to, item.created >= to { return false }
            let haystack = ((item.source?.absoluteString ?? "") + " " + item.name).lowercased()
            return terms.allSatisfy { term in term.hasPrefix("-") ? !haystack.contains(term.dropFirst().lowercased()) : haystack.contains(term.lowercased()) }
        }.sorted { left, right in
            for key in order {
                let descending = key.hasPrefix("-")
                switch key.trimmingCharacters(in: CharacterSet(charactersIn: "-")) {
                case "filename" where left.name != right.name: return descending ? left.name > right.name : left.name < right.name
                case "id" where left.browserID != right.browserID: return descending ? (left.browserID ?? 0) > (right.browserID ?? 0) : (left.browserID ?? 0) < (right.browserID ?? 0)
                case "startTime" where left.created != right.created: return descending ? left.created > right.created : left.created < right.created
                default: continue
                }
            }
            return left.id.uuidString < right.id.uuidString
        }.prefix(limit == 0 ? Int.max : limit))
    }

    func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        guard Extensions.asks(context, for: "downloads"), Session.shared.canUseWorkspace else { throw Extensions.Unanswered(why: "This extension does not have download access.") }
        Downloads.shared.assignBrowserIDs()
        let first = args.first
        if api == "downloads.download" {
            let options = first as? [String: Any] ?? [:]
            guard let url = (options["url"] as? String).flatMap(URL.init(string:)), ["http", "https", "data"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  url.host().map(ExtensionPolicy.mayTouchData(ofDomain:)) ?? true else { throw Extensions.Unanswered(why: "This browser cannot download from protected sign-in pages, local files, or another extension.") }
            let name = options["filename"] as? String
            if let name, name.isEmpty || name.contains("/") || name.contains("\\") || name == "." || name == ".." || name.contains("\0") {
                throw Extensions.Unanswered(why: "This browser cannot choose download subfolders. Use a file name without slashes.")
            }
            guard options["conflictAction"] == nil || ["uniquify", "prompt"].contains(options["conflictAction"] as? String ?? ""),
                  options["incognito"] as? Bool != true else { throw Extensions.Unanswered(why: "This browser cannot overwrite a download or download in a private window through an extension.") }
            var request = URLRequest(url: url)
            let method = options["method"] as? String ?? "GET"
            guard ["GET", "POST"].contains(method) else { throw Extensions.Unanswered(why: "Only GET and POST downloads are supported.") }
            request.httpMethod = method
            request.httpBody = (options["body"] as? String)?.data(using: .utf8)
            let forbidden = Set(["host", "cookie", "connection", "content-length", "origin", "referer", "proxy-authorization"])
            for header in options["headers"] as? [[String: String]] ?? [] {
                guard let name = header["name"], let value = header["value"], !forbidden.contains(name.lowercased()),
                      !name.contains(where: { $0.isNewline }), !value.contains(where: { $0.isNewline }) else { throw Extensions.Unanswered(why: "This browser cannot set that download header.") }
                request.setValue(value, forHTTPHeaderField: name)
            }
            let item = await Downloads.shared.startExtensionDownload(request, in: space, name: name,
                                                                     saveAs: options["saveAs"] as? Bool == true || options["conflictAction"] as? String == "prompt")
            return item.browserID
        }
        if ["downloads.search", "downloads.erase"].contains(api) {
            let found = try search(first as? [String: Any] ?? [:], in: space)
            if api == "downloads.search" { return found.map(describe) }
            guard found.allSatisfy({ $0.phase != .downloading }) else { throw Extensions.Unanswered(why: "Cancel active downloads before removing their activity.") }
            Downloads.shared.eraseExtensionActivity(Set(found.map(\.id)), in: space)
            return found.compactMap(\.browserID)
        }
        if api == "downloads.showDefaultFolder" {
            if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(folder) }
            return nil
        }
        guard let id = first as? Int, let item = Downloads.shared.items.first(where: { $0.space == space && $0.browserID == id }) else { throw Extensions.Unanswered(why: "Download not found in this space.") }
        switch api {
        case "downloads.cancel": Downloads.shared.cancel(item); return nil
        case "downloads.resume":
            guard item.canResume else { throw Extensions.Unanswered(why: "The server did not provide data to resume this download.") }
            Downloads.shared.retry(item); return nil
        case "downloads.show":
            guard let file = item.file, FileManager.default.fileExists(atPath: file.path) else { throw Extensions.Unanswered(why: "The downloaded file is no longer available.") }
            NSWorkspace.shared.activateFileViewerSelecting([file]); return nil
        case "downloads.removeFile":
            guard item.finished, let file = item.file else { throw Extensions.Unanswered(why: "The download is not complete.") }
            try FileManager.default.removeItem(at: file)
            Downloads.shared.extensionFileRemoved(item.id)
            return nil
        case "downloads.getFileIcon":
            guard let file = item.file, let data = NSWorkspace.shared.icon(forFile: file.path).tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        default: throw Extensions.Unanswered(why: "This browser cannot pause downloads, open downloaded files automatically, or hide its download controls through an extension.")
        }
    }
}
