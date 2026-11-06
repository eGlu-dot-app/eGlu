#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit

/// Source scans and first-seconds trials. The app keeps verdicts and warnings.
@MainActor
public final class WebKitExtensionCompatibility: WebExtensionCompatibility {
    // Shared across all spaces, just as the hub's original static table was.
    public static let apiTable = ExtensionTable(scheme: "chrome-extension")
    private let host: any ExtensionCompatibilityHost
    private let contexts: () -> [UUID: [String: WKWebExtensionContext]]
    private let manifests: () -> [String: ExtensionManifest]
    private let lacking: () -> [String: Set<String>]
    private let setMissing: (Set<String>, String) -> Void
    private let errorsChanged: (WKWebExtensionContext, String, UUID) -> Void
    private let package: (String, String) -> URL
    private let prepared: (String, String) -> URL
    private let application: () -> String
    private let scheme: String
    private let shimApplication: String
    private let letRulesRedirect: (WKWebExtensionContext, WKWebExtension) -> Void
    private let sites: (WKWebExtension) -> [WKWebExtension.MatchPattern]
    private let fence: (WKWebExtensionContext) -> Void
    private let defaults: UserDefaults

    public init(host: any ExtensionCompatibilityHost,
                contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                manifests: @escaping () -> [String: ExtensionManifest],
                lacking: @escaping () -> [String: Set<String>],
                setMissing: @escaping (Set<String>, String) -> Void,
                errorsChanged: @escaping (WKWebExtensionContext, String, UUID) -> Void,
                package: @escaping (String, String) -> URL, prepared: @escaping (String, String) -> URL,
                application: @escaping () -> String, scheme: String, shimApplication: String,
                letRulesRedirect: @escaping (WKWebExtensionContext, WKWebExtension) -> Void,
                sites: @escaping (WKWebExtension) -> [WKWebExtension.MatchPattern],
                fence: @escaping (WKWebExtensionContext) -> Void, defaults: UserDefaults = .standard) {
        self.host = host
        self.contexts = contexts
        self.manifests = manifests
        self.lacking = lacking
        self.setMissing = setMissing
        self.errorsChanged = errorsChanged
        self.package = package
        self.prepared = prepared
        self.application = application
        self.scheme = scheme
        self.shimApplication = shimApplication
        self.letRulesRedirect = letRulesRedirect
        self.sites = sites
        self.fence = fence
        self.defaults = defaults
    }

    // Tests replace execution, never loading an installed extension or a site.
    var scanForTesting: ((URL, ExtensionManifest, Set<String>) async -> [String])?
    var trialForTesting: ((URL, String, ExtensionManifest, Set<String>) async -> ExtensionTrial.Checked)?
    var delayForTesting: (() async -> Void)?
    var tableForTesting: (() -> ExtensionAPITable?)?
    var measureForTesting: (() async -> ExtensionAPITable?)?
    var environmentForTesting: ExtensionCheckEnvironment?

    private var table: ExtensionAPITable? {
        if let tableForTesting { return tableForTesting() }
        return Self.apiTable.table
    }
    private var environment: ExtensionCheckEnvironment { environmentForTesting ?? checkEnvironment }
    private func measured() async -> ExtensionAPITable? {
        if let measureForTesting { return await measureForTesting() }
        return await Self.apiTable.measured()
    }

    /// What trying a version's pages on a copy found, by id, once a version
    /// (ExtensionTrial.check); kept across launches.
    public private(set) var checked: [String: (version: String, result: ExtensionTrial.Checked)] = [:]
    /// The version being tried, by id.
    private var checking: [String: String] = [:]
    /// What reading each extension's code found (notes), by id, for the
    /// version and the APIs missing it was read against; and the reading
    /// under way. A password manager's scripts run to megabytes, and read
    /// on the main thread, once a space, they held the browser for
    /// seconds as it loaded.
    public var scanned: [String: (key: String, notes: [String])] = [:]
    public var scanning: [String: (key: String, attempt: UUID)] = [:]
    /// What it asks for that nothing on this Mac answers: against this
    /// Mac's measured table (ExtensionTable) once there is one; before,
    /// what WebKit dropped and no shim answers. A permission's name is its
    /// namespace's.
    public func missing(for manifest: ExtensionManifest, _ package: WKWebExtension) -> Set<String> {
        let kept = Set((package.requestedPermissions.union(package.optionalPermissions)).map(\.rawValue))
        let asked = manifest.permissions + manifest.optionalPermissions
        var missing: Set<String>
        if let table = table {
            missing = table.missing(asked: asked, kept: kept)
            if manifest.usesChromeSignIn, !table.works("identity.getAuthToken") { missing.insert("identity.getAuthToken") }
        } else {
            let shims = ExtensionAPITable(answers: ExtensionAPITable.shims)
            missing = Set(manifest.dropped(kept: kept).filter { $0 != "cookies" && !shims.works($0) }
                + (manifest.usesChromeSignIn ? ["identity.getAuthToken"] : []))
        }
        // EyeDropper is a web API no permission names, so neither list holds
        // it; the shim answers it through the Mac's colour sampler. Should
        // the shim stop doing so, it goes back to being missing.
        if !Scripts.extensionShim.contains("eyeDropper") { missing.insert("EyeDropper") }
        return missing
    }

    public static func scanKey(_ version: String, _ missing: Set<String>) -> String {
        version + "|" + missing.sorted().joined(separator: ",")
    }

    /// Its code read for what it reaches for (notes), off the main thread,
    /// once for its version and what it lacks; what was found goes to every
    /// space it is loaded in.
    public func readCode(of item: WebExtensionCompatibilityInstallation) {
        guard let manifest = manifests()[item.id], let missing = lacking()[item.id] else { return }
        let key = Self.scanKey(item.version, missing)
        let found = { [weak self] (notes: [String]) in
            guard let self else { return }
            for space in self.contexts().keys where self.contexts()[space]?[item.id] != nil {
                self.host.extensionCompatibilityEvidence(.notes(notes), id: item.id, in: space)
            }
        }
        if let done = scanned[item.id], done.key == key { return found(done.notes) }
        guard scanning[item.id]?.key != key else { return }
        let attempt = UUID()
        scanning[item.id] = (key, attempt)
        let file = package(item.id, item.version)
        Task {
            let notes: [String]
            if let scanForTesting {
                notes = await scanForTesting(file, manifest, missing)
            } else {
                notes = await Task.detached(priority: .utility) {
                    (try? Data(contentsOf: file)).map { Self.notes(in: $0, manifest, missing: missing) } ?? []
                }.value
            }
            // Updated, or read against a newer table, meanwhile: that reading wins.
            guard scanning[item.id]?.attempt == attempt else { return }
            scanning[item.id] = nil
            scanned[item.id] = (key, notes)
            found(notes)
        }
    }

    /// What its code reaches for, untested, that nothing here answers.
    nonisolated private static func notes(in archive: Data, _ manifest: ExtensionManifest, missing: Set<String>) -> [String] {
        var notes: [String] = []
        for file in manifest.files.map(ExtensionPreparation.normalized) where file.hasSuffix(".js") {
            guard let source = ZipFile.file(in: archive, matching: { ExtensionPreparation.normalized($0) == file }) else { continue }
            let uses = ExtensionScan.uses(in: String(decoding: source, as: UTF8.self), file: file, of: missing)
            for use in uses where !use.tested && !notes.contains(use.path) { notes.append(use.path) }
        }
        return notes
    }

    /// This Mac's table measured, the first time on a macOS build: what
    /// each loaded extension lacks read again against it.
    public func measureTable() async {
        guard table == nil, await measured() != nil else { return }
        for item in host.extensionCompatibilityInstallations {
            guard let space = contexts().first(where: { $0.value[item.id] != nil })?.key, let context = contexts()[space]?[item.id],
                  let manifest = manifests()[item.id]
            else { continue }
            let missing = missing(for: manifest, context.webExtension)
            setMissing(missing, item.id)
            readCode(of: item)
            for space in contexts().keys where contexts()[space]?[item.id] != nil {
                // Its errors so far, read again against what it lacks now.
                if let context = contexts()[space]?[item.id] { errorsChanged(context, item.id, space) }
            }
        }
    }

    // MARK: Its pages, tried on a copy

    private static let checkedKey = "extensionsPagesTried"

    private static func probe(_ probe: ExtensionEvidence.Probe) -> String {
        switch probe {
        case .notApplicable: return "none"
        case .checking: return "checking"
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .timedOut: return "timedOut"
        }
    }

    private static func probe(_ word: String?) -> ExtensionEvidence.Probe {
        ["passed": .passed, "failed": .failed, "skipped": .skipped, "timedOut": .timedOut][word ?? ""] ?? .notApplicable
    }

    public static func apply(_ result: ExtensionTrial.Checked, to seen: inout ExtensionEvidence) {
        seen.testPage = result.testPage
        seen.popup = result.popup
        seen.optionsPage = result.optionsPage
        seen.problems.formUnion(result.problems.map(\.problem))
    }

    /// What a check's result holds for: the extension's version on this
    /// macOS build, eGlu and shim. Any of them new, it is tried again.
    private lazy var checkEnvironment = ExtensionCheckEnvironment(
        system: ExtensionTable.build, application: application(),
        shim: ExtensionPreparation.stamp(for: Scripts.extensionShim))

    public func checkStamp(_ version: String) -> String { environment.stamp(for: version) }

    public func currentFailures(_ held: [String: String], installed: [String: String]) -> [String: String] {
        environment.currentFailures(held, installed: installed)
    }

    /// Its content scripts, popup and settings page tried on a copy, once a
    /// version, a few seconds after it first loads; what was found goes to
    /// every space it is on in. Kept, so a relaunch doesn't try them again.
    public func checkCopy(of item: WebExtensionCompatibilityInstallation) {
        let stamp = checkStamp(item.version)
        if checked.isEmpty, let kept = defaults.dictionary(forKey: Self.checkedKey) as? [String: [String: Any]] {
            for (id, entry) in kept {
                guard let held = entry["stamp"] as? String else { continue }
                let problems = (entry["problems"] as? [String] ?? []).compactMap { line -> (ExtensionError.Problem, String?)? in
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2, ExtensionError.isAPIPath(parts[1]),
                          let kind = ["missing": ExtensionError.Kind.missing, "notAFunction": .notAFunction, "wrongArguments": .wrongArguments][parts[0]]
                    else { return nil }
                    return (ExtensionError.Problem(kind: kind, api: parts[1]), nil)
                }
                checked[id] = (held, ExtensionTrial.Checked(testPage: Self.probe(entry["testPage"] as? String), popup: Self.probe(entry["popup"] as? String),
                                                            optionsPage: Self.probe(entry["optionsPage"] as? String), problems: problems))
            }
        }
        let apply = { [weak self] (result: ExtensionTrial.Checked) in
            guard let self else { return }
            for space in self.contexts().keys where self.contexts()[space]?[item.id] != nil {
                self.host.extensionCompatibilityEvidence(.checked(Self.evidence(result)), id: item.id, in: space)
            }
        }
        if let done = checked[item.id], done.version == stamp { return apply(done.result) }
        guard let manifest = manifests()[item.id], checking[item.id] == nil else { return }
        checking[item.id] = item.version
        for space in contexts().keys where contexts()[space]?[item.id] != nil {
            host.extensionCompatibilityEvidence(.checking(testPage: !manifest.contentScripts.isEmpty,
                                                         popup: manifest.popup != nil, optionsPage: manifest.optionsPage != nil),
                                                id: item.id, in: space)
        }
        Task {
            if let delayForTesting { await delayForTesting() } else { try? await Task.sleep(for: .seconds(2)) }
            // Read against this Mac's table, measured first on a new build.
            if table == nil { await measureTable() }
            let result: ExtensionTrial.Checked
            if let trialForTesting {
                result = await trialForTesting(prepared(item.id, item.version), item.id, manifest, lacking()[item.id] ?? [])
            } else {
                result = await ExtensionTrial.check(prepared(item.id, item.version), id: item.id, manifest: manifest,
                                                    missing: lacking()[item.id] ?? [], scheme: scheme, shimApplication: shimApplication,
                                                    letRulesRedirect: letRulesRedirect, sites: sites, fence: fence)
            }
            checking[item.id] = nil
            // Updated meanwhile: the version now on is tried instead; removed, nothing.
            guard let now = host.extensionCompatibilityInstallation(item.id) else { return }
            guard now.version == item.version else {
                if contexts().values.contains(where: { $0[item.id] != nil }) { checkCopy(of: now) }
                return
            }
            checked[item.id] = (stamp, result)
            var kept = defaults.dictionary(forKey: Self.checkedKey) ?? [:]
            kept[item.id] = ["stamp": stamp, "testPage": Self.probe(result.testPage), "popup": Self.probe(result.popup),
                             "optionsPage": Self.probe(result.optionsPage),
                             "problems": result.problems.map { "\($0.problem.kind) \($0.problem.api)" }] as [String: Any]
            defaults.set(kept, forKey: Self.checkedKey)
            for found in Self.evidence(result).problems { host.extensionCompatibilityProblem(found, of: item) }
            apply(result)
        }
    }

    public func forgetCheck(_ id: String) {
        checked[id] = nil
        var kept = defaults.dictionary(forKey: Self.checkedKey) ?? [:]
        kept[id] = nil
        defaults.set(kept, forKey: Self.checkedKey)
    }

    private static func evidence(_ result: ExtensionTrial.Checked) -> WebExtensionCompatibilityResult {
        WebExtensionCompatibilityResult(testPage: evidence(result.testPage), popup: evidence(result.popup),
                                        optionsPage: evidence(result.optionsPage), problems: result.problems.map {
            let kind: WebExtensionCompatibilityResult.Problem.Kind
            switch $0.problem.kind {
            case .missing: kind = .missing
            case .notAFunction: kind = .notAFunction
            case .wrongArguments: kind = .wrongArguments
            }
            return .init(kind: kind, api: $0.problem.api, file: $0.file)
        })
    }

    private static func evidence(_ probe: ExtensionEvidence.Probe) -> WebExtensionCompatibilityResult.Probe {
        switch probe {
        case .notApplicable: return .notApplicable
        case .checking: return .checking
        case .passed: return .passed
        case .failed: return .failed
        case .skipped: return .skipped
        case .timedOut: return .timedOut
        }
    }
}
#endif
