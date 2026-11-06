#if os(macOS)
import CryptoKit
import Foundation
import PadCore
import WebEngineAppKit
import WebKit

/// Generated files and the shim's answers about them. Like the original
/// Extensions members, these run on the main actor. Pruning state is shared
/// by every space and runtime instance for the life of the process.
@MainActor
public final class WebKitExtensionScriptAnswers: WebExtensionScriptAnswers {
    private let host: any ExtensionScriptHost
    private let prepared: (String, String) -> URL
    private let unanswered: (String) -> any Error

    public init(host: any ExtensionScriptHost, prepared: @escaping (String, String) -> URL,
                unanswered: @escaping (String) -> any Error) {
        self.host = host
        self.prepared = prepared
        self.unanswered = unanswered
    }

    /// Only for an extension WebKit lets inject scripts at all.
    public func scripting(_ first: Any?, arguments args: [Any], id: String, context: WKWebExtensionContext) throws -> String {
        guard context.hasPermission(.scripting) else { throw unanswered("The extension never asked for \u{201C}scripting\u{201D}") }
        guard let item = host.extensionScriptInstallation({ id }) else { throw unanswered("No such extension.") }
        return try scriptingFile(first as? String ?? "", arguments: args.dropFirst().first as? [Any] ?? [],
                                 in: prepared(item.id, item.version))
    }

    public func userScriptFile(_ first: Any?, of id: String) throws -> String {
        guard let item = host.extensionScriptInstallation({ id }) else { throw unanswered("No such extension.") }
        return try userScriptFile(first as? [String: Any] ?? [:], in: prepared(item.id, item.version))
    }

    /// A function an extension's page in a website's frame asked its worker
    /// to inject, which can't cross the message as a function: written as a
    /// file of the extension's own, called with its JSON arguments, for
    /// WebKit's scripting to take by path. A megabyte of source at most, and
    /// one more than a minute old is let go, so a page gone wrong can't fill
    /// the extension's folder. (Search's ba34243)
    public func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        guard !function.isEmpty, JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments), let given = String(data: data, encoding: .utf8)
        else { throw unanswered("Invalid script function or arguments") }
        let source = "(\(ExtensionPreparation.expression(of: function)))(...\(given))\n"
        // A megabyte in all, the arguments counted too.
        guard source.utf8.count <= 1_000_000 else { throw unanswered("Invalid script function or arguments") }
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let folder = folder.appendingPathComponent("_eglu", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) { try source.write(to: file, atomically: true, encoding: .utf8) }
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("script-") && old != file {
            let age = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: old) }
        }
        return "_eglu/" + name
    }

    /// What eGlu keeps for an extension in a space beside its versions
    /// (user scripts, their worlds), which an update leaves and a removal
    /// from the space takes (clear).
    public func kept(_ name: String, of id: String, in space: UUID) -> URL {
        host.extensionScriptRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("_eglu", isDirectory: true)
            .appendingPathComponent("\(name)-\(space.uuidString).json")
    }

    /// A user script (chrome.userScripts) written into a file of the
    /// extension's, by its content, for WebKit to register as a content
    /// script: its code, or the extension's own files it names and nothing
    /// outside its folder, inside a block that leaves when the page isn't
    /// one its globs take. Outside the page's own world it gets only
    /// runtime's messages, tagged for onUserScriptMessage, as Chrome's
    /// USER_SCRIPT world has. (Search's)
    public func userScriptFile(_ script: [String: Any], in folder: URL, writing: Bool = true) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String, let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __egluUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "eglu-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* eGlu: a user script (chrome.userScripts) */
        eglu_user_script: {
          const __egluHref = location.href;
          const __egluGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __egluIn = \#(json(script["includeGlobs"] ?? [])), __egluOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__egluIn.length && !__egluIn.some((g) => __egluGlob(g).test(__egluHref))) || __egluOut.some((g) => __egluGlob(g).test(__egluHref))) break eglu_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        guard writing else { return "_eglu/" + name }
        let dir = folder.appendingPathComponent("_eglu", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_eglu/" + name
    }

    /// User-script files no space's list names any more, let go: an edited
    /// script gets a file of its own each time. One made in the last minute
    /// stays, as an execute's may still be on its way into a page.
    public func pruneUserScripts(of id: String, in folder: URL) {
        // At most once a minute for an extension, as it reads every space's
        // list: one asked for sooner runs when the minute is up.
        let since = Date().timeIntervalSince(Self.pruned[id] ?? .distantPast)
        guard since > 60 else {
            guard !Self.prunePending.contains(id) else { return }
            Self.prunePending.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + (60 - since) + 1) {
                MainActor.assumeIsolated {
                    Self.prunePending.remove(id)
                    self.pruneUserScripts(of: id, in: folder)
                }
            }
            return
        }
        Self.pruned[id] = Date()
        let lists = kept("userscripts", of: id, in: UUID()).deletingLastPathComponent()
        var named = Set<String>()
        for list in (try? FileManager.default.contentsOfDirectory(at: lists, includingPropertiesForKeys: nil)) ?? []
        where list.lastPathComponent.hasPrefix("userscripts-") {
            for script in (try? JSONSerialization.jsonObject(with: Data(contentsOf: list))) as? [[String: Any]] ?? [] {
                if let file = try? userScriptFile(script, in: folder, writing: false) { named.insert((file as NSString).lastPathComponent) }
            }
        }
        let dir = folder.appendingPathComponent("_eglu", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where file.lastPathComponent.hasPrefix("us-") && !named.contains(file.lastPathComponent) {
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    static var pruned: [String: Date] = [:]
    static var prunePending: Set<String> = []

    /// One of the extension's own files, and nothing outside its folder: a
    /// name is resolved, links and all, before it is read.
    private func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    public func userScripts(of id: String, in space: UUID) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: kept("userscripts", of: id, in: space)))) ?? []
    }

    public func changeUserScripts(_ first: Any?, of id: String, in space: UUID) throws -> [[String: Any]] {
        // Read, changed and written in one go, here on the main actor: two
        // of the extension's pages registering at once both keep theirs.
        let file = kept("userscripts", of: id, in: space)
        var scripts = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
        let change = first as? [String: Any] ?? [:]
        func named(_ script: [String: Any]) -> String { script["id"] as? String ?? "" }
        for added in change["add"] as? [[String: Any]] ?? [] {
            guard !scripts.contains(where: { named($0) == named(added) }) else { throw unanswered("Duplicate script id '\(named(added))'") }
            scripts.append(added)
        }
        for updated in change["update"] as? [[String: Any]] ?? [] {
            guard let at = scripts.firstIndex(where: { named($0) == named(updated) }) else {
                throw unanswered("Script with id '\(named(updated))' does not exist")
            }
            scripts[at].merge(updated) { $1 }
        }
        let removed = Set(change["remove"] as? [String] ?? [])
        scripts.removeAll { removed.contains(named($0)) }
        guard JSONSerialization.isValidJSONObject(scripts) else { throw unanswered("Invalid scripts.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: scripts).write(to: file, options: .atomic)
        if let item = host.extensionScriptInstallation({ id }) { pruneUserScripts(of: id, in: prepared(item.id, item.version)) }
        return scripts
    }

    public func userScriptWorlds(of id: String, in space: UUID) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: kept("worlds", of: id, in: space)))) as? [[String: Any]] ?? []
    }

    public func setUserScriptWorld(_ first: Any?, of id: String, in space: UUID) throws {
        let file = kept("worlds", of: id, in: space)
        var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
        let properties = first as? [String: Any] ?? [:]
        let world = properties["worldId"] as? String ?? ""
        worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
        if properties["reset"] as? Bool != true, JSONSerialization.isValidJSONObject(properties) { worlds.append(properties) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: worlds).write(to: file, options: .atomic)
    }

    /// The context stays WebKit's own. The general runtime contract does
    /// not expose the shim's dispatch or WebKit's context.
    public func management(_ api: String, first: Any?, id: String, context: WKWebExtensionContext) throws -> [String: Any] {
        if api == "management.get", first as? String != id { throw unanswered("No extension with id \(first ?? "")") }
        return describe(context)
    }

    /// management's ExtensionInfo, of the extension itself.
    private func describe(_ context: WKWebExtensionContext) -> [String: Any] {
        let package = context.webExtension
        let item = host.extensionScriptInstallation { context.uniqueIdentifier }
        var info: [String: Any] = [
            "id": context.uniqueIdentifier,
            "name": WebKitExtensionMetadata.name(of: package) ?? item?.name ?? "",
            "shortName": package.displayShortName ?? WebKitExtensionMetadata.name(of: package) ?? "",
            "description": package.displayDescription ?? "",
            "version": package.version ?? item?.version ?? "",
            "enabled": true, "mayDisable": true, "offlineEnabled": false,
            "type": "extension",
            "installType": item?.isUnsigned == true ? "development" : "normal",
            "permissions": package.requestedPermissions.map(\.rawValue).sorted(),
            "hostPermissions": package.allRequestedMatchPatterns.map(\.string).sorted(),
            "isApp": false,
        ]
        if let options = WebKitExtensionMetadata.optionsPageURL(for: context) { info["optionsUrl"] = options.absoluteString }
        return info
    }

}
#endif
