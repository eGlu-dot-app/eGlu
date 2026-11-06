#if os(macOS)
import Foundation
import PadCore
import WebEngineAppKit
import WebKit

/// Error observation, sanitized records and evidence, on the hub's main
/// actor. Context and manifest closures are temporary composition seams
/// until their owning hub slices move into the composed runtime.
@MainActor
public final class WebKitExtensionEvidence: WebExtensionEvidenceRuntime {
    private let host: any ExtensionEvidenceHost
    private let contexts: () -> [UUID: [String: WKWebExtensionContext]]
    private let manifests: () -> [String: ExtensionManifest]
    private let folder: () -> URL
    private let recordsFile: () -> URL
    private let readErrors: (WKWebExtensionContext) -> [any Error]
    private let debugError: (String, () -> String) -> Void
    public var evidence: [UUID: [String: WebExtensionEvidence]] = [:]
    public var lacking: [String: Set<String>] = [:]
    /// Only fingerprints, never the error's words, until the context unloads.
    public var recorded: [String: Set<String>] = [:]
    /// Temporary forwards keep the other hub slices' cleanup order intact.
    public var recordCollection = ExtensionRecords()
    public var watches: [UUID: [String: NSObjectProtocol]] = [:]

    public convenience init(host: any ExtensionEvidenceHost,
                contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                manifests: @escaping () -> [String: ExtensionManifest],
                folder: @escaping () -> URL, recordsFile: @escaping () -> URL,
                debugError: @escaping (String, () -> String) -> Void = { _, _ in }) {
        self.init(host: host, contexts: contexts, manifests: manifests, folder: folder,
                  recordsFile: recordsFile, defaults: .standard, readErrors: { $0.errors }, debugError: debugError)
    }

    // Tests supply errors without loading an extension or starting a worker.
    init(host: any ExtensionEvidenceHost,
         contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
         manifests: @escaping () -> [String: ExtensionManifest],
         folder: @escaping () -> URL, recordsFile: @escaping () -> URL,
         defaults: UserDefaults, readErrors: @escaping (WKWebExtensionContext) -> [any Error],
         debugError: @escaping (String, () -> String) -> Void = { _, _ in }) {
        self.host = host
        self.contexts = contexts
        self.manifests = manifests
        self.folder = folder
        self.recordsFile = recordsFile
        self.debugError = debugError
        self.readErrors = readErrors
    }

    /// Whether an error is new to the records for "space/id"; at most 500
    /// remembered, which is past what the records keep.
    public func recordOnce(_ key: String, _ text: String) -> Bool {
        guard recorded[key, default: []].count < 500 else { return false }
        return recorded[key, default: []].insert(Self.fingerprint(text)).inserted
    }

    /// An error's fingerprint, to know it again without keeping its words.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    public func watch(_ context: WKWebExtensionContext, _ id: String, in space: UUID) {
        watches[space, default: [:]][id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main
        ) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                self.errorsChanged(context, id, in: space)
            }
        }
    }

    public func unwatch(_ id: String, in space: UUID) {
        if let token = watches[space]?.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
    }

    public func errorsChanged(_ context: WKWebExtensionContext, _ id: String, in space: UUID) {
        guard contexts()[space]?[id] === context else { return }
        let missing = lacking[id] ?? []
        // WebKit records a worker that failed to start as an error, and
        // doesn't try again: the extension would be dead until someone
        // noticed. It is taken up afresh two seconds after. (Search)
        let failed = readErrors(context).contains {
            let error = $0 as NSError
            return error.domain == WKWebExtensionContext.errorDomain
                && error.code == WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue
        }
        let key = "\(space.uuidString)/\(id)"
        let recovery = host.extensionErrorsChanged(id, in: space, failed: failed)
        let item = recovery.installation
        update(id, in: space) { seen in
            for error in readErrors(context) {
                let nsError = error as NSError
                if nsError.domain == WKWebExtensionContext.errorDomain,
                   nsError.code == WKWebExtensionContext.Error.Code.backgroundContentFailedToLoad.rawValue, recovery.restarting {
                    seen.start = .failed
                }
                if let problem = ExtensionError.problem(in: nsError.localizedDescription, missing: missing) {
                    seen.problems.insert(Self.problem(problem))
                    // Once each error into the records: the list is whole each time.
                    if let item, recordOnce(key, nsError.localizedDescription) {
                        debugError(problem.api) { nsError.localizedDescription }
                        note(Self.problem(problem), file: ExtensionError.place(in: nsError.localizedDescription)?.file, of: item)
                    }
                }
            }
        }
    }

    // MARK: The records

    public func readRecords() {
        guard let data = try? Data(contentsOf: recordsFile()), let kept = try? JSONDecoder().decode(ExtensionRecords.self, from: data) else { return }
        recordCollection = kept
        pruneRecords()
    }

    /// Past 30 days, gone from the file too.
    public func pruneRecords() {
        let before = recordCollection
        recordCollection.prune()
        if recordCollection != before { saveRecords() }
    }

    public func saveRecords() {
        do {
            try FileManager.default.createDirectory(at: folder(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recordCollection).write(to: recordsFile(), options: .atomic)
        } catch {
            NSLog("eGlu: couldn't save the extension records: \(error.localizedDescription)")
        }
    }

    /// A problem it ran into, kept: where in it and what, never the error's words.
    public func note(_ value: WebExtensionEvidence.Problem, file: String?, of item: WebExtensionEvidenceInstallation) {
        let kind: ExtensionError.Kind
        switch value.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        let problem = ExtensionError.Problem(kind: kind, api: value.api)
        let place = file.flatMap { file in manifests()[item.id].map { ExtensionRecords.place(of: file, in: $0) } } ?? "page"
        let now = Date()
        recordCollection.note(.init(id: item.id, version: item.version, eglu: host.extensionEvidenceAppVersion, macOS: host.extensionEvidenceOSVersion,
                           shim: ExtensionPreparation.stamp(for: Scripts.extensionShim), place: place, api: problem.api,
                           kind: "\(problem.kind)", first: now, last: now))
        saveRecords()
    }

    public func records(of id: String) -> [WebExtensionErrorRecord] {
        pruneRecords()
        return recordCollection.of(id).map {
            WebExtensionErrorRecord(id: $0.id, version: $0.version, eglu: $0.eglu, macOS: $0.macOS,
                shim: $0.shim, place: $0.place, api: $0.api, kind: $0.kind, count: $0.count, first: $0.first, last: $0.last)
        }
    }

    public func update(_ id: String, in space: UUID, _ change: (inout WebExtensionEvidence) -> Void) {
        guard var seen = evidence[space]?[id] else { return }
        change(&seen)
        record(seen, id, in: space)
    }

    public func record(_ seen: WebExtensionEvidence, _ id: String, in space: UUID) {
        evidence[space, default: [:]][id] = seen
        host.extensionEvidenceChanged(seen, id, in: space)
    }

    private static func problem(_ value: ExtensionError.Problem) -> WebExtensionEvidence.Problem {
        let kind: WebExtensionEvidence.Problem.Kind
        switch value.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        return .init(kind: kind, api: value.api)
    }
}
#endif
