import Foundation
import Testing
@testable import PadCore

struct ExtensionPresentationTests {
    @Test func siteScopePreservesHostTransportAndPath() {
        #expect(ExtensionAccessDescription.site("https://*.example.com/private/*") == "example.com and its subdomains, pages matching /private/* over HTTPS")
        #expect(ExtensionAccessDescription.site("https://example.com/*") == "example.com over HTTPS")
        #expect(ExtensionAccessDescription.site("<all_urls>") == "All websites")
        #expect(ExtensionAccessDescription.site("http://*/*") == "All HTTP websites")
    }
    /// Said only where cookies are being given (a request): what a yes
    /// reaches. Held cookies are never a line of what it may do (below).
    @Test func cookiesSayTheyReachSignIns() {
        #expect(ExtensionAccessDescription.capability("cookies").contains("sign-ins"))
    }
    /// Common permissions are said in words, not by their manifest names.
    @Test(arguments: ["webNavigation", "idle", "tabGroups", "browsingData", "topSites", "sessions", "system.display"])
    func commonPermissionsHavePlainWords(permission: String) {
        let words = ExtensionAccessDescription.capability(permission)
        #expect(!words.contains("additional capability"))
        #expect(!words.contains("(\(permission))"))
    }
    /// 1Password's manifest: broad patterns make every listed site part of
    /// "all websites", and routine capabilities wait for Show All.
    @Test func broadSitesSummarizeAsAllWebsites() {
        let summary = ExtensionAccessSummary(
            permissions: ["storage", "tabs", "alarms", "webNavigation", "nativeMessaging", "scripting", "webRequestAuthProvider", "futureThing"],
            sites: ["<all_urls>", "https://*.1password.com/*", "https://www.director.ai/complete-1password-pairing?*", "http://localhost/*"])
        #expect(summary.reach == .everywhere)
        #expect(summary.siteHeadline(onClick: false) == "Read and change pages on all websites")
        #expect(summary.notable.map(\.text).contains("Read the addresses and titles of your tabs"))
        #expect(summary.notable.map(\.text).contains("Answer sites' requests to sign in"))
        #expect(summary.notable.contains { $0.text.contains("(futureThing)") })
        #expect(!summary.notable.map(\.text).contains("Store its settings and data on this Mac"))
        #expect(summary.routine.map(\.text).contains("Run scripts on sites you allow"))
        #expect(summary.siteLines.count == 4)
    }
    @Test func listedSitesAreNamedOnceEach() {
        let summary = ExtensionAccessSummary(permissions: [], sites: [
            "https://*.example.com/*", "https://www.director.ai/", "https://www.director.ai/?*", "http://localhost:8080/*",
        ])
        #expect(summary.reach == .hosts(["example.com", "localhost", "www.director.ai"]))
        #expect(summary.siteHeadline(onClick: false)?.contains("example.com") == true)
        #expect(summary.siteHeadline(onClick: true) == "Read and change the page you're on, only when you click it")
        let many = ExtensionAccessSummary(permissions: [], sites: ["https://a.com/*", "https://b.com/*", "https://c.com/*", "https://d.com/*"])
        #expect(many.siteHeadline(onClick: false) == "Read and change pages on 4 sites")
    }
    /// Grammarly's: cookies are the person's choice, so not a line of what
    /// it may do, and not hidden among the routine ones either.
    @Test func cookiesAreAChoiceNotALine() {
        let summary = ExtensionAccessSummary(permissions: ["cookies", "storage"], sites: [])
        #expect(summary.cookies)
        #expect(!(summary.notable + summary.routine).contains { $0.symbol == ExtensionAccessDescription.symbol("cookies") })
        #expect(!ExtensionAccessSummary(permissions: ["cookies"], sites: []).isEmpty)
        #expect(!ExtensionAccessSummary(permissions: ["storage"], sites: []).cookies)
    }
    @Test func grantsSplitIntoSitesAndCapabilities() {
        let summary = ExtensionAccessSummary(grants: ["site:file:///*", "site:https://*/*", "contextMenus", "menus"])
        #expect(summary.localFiles)
        #expect(summary.reach == .everywhere)
        #expect(summary.routine.count == 1)
        #expect(ExtensionAccessSummary(grants: []).isEmpty)
    }
    @Test func manifestIconIsItsLargest() throws {
        let json = #"{"name":"x","version":"1","icons":{"16":"i16.png","128":"/icons/i128.png","48":"i48.png"}}"#
        #expect(try ExtensionManifest(json: Data(json.utf8)).icon == "icons/i128.png")
        let button = #"{"name":"x","version":"1","action":{"default_icon":"b.png"}}"#
        #expect(try ExtensionManifest(json: Data(button.utf8)).icon == "b.png")
    }
    @Test(arguments: [ExtensionUpdateReport.Outcome.failed, .declined, .deferred])
    func zeroUpdatedIsNotASuccess(outcome: ExtensionUpdateReport.Outcome) {
        let report = ExtensionUpdateReport(entries: [.init(id: "one", name: "One", outcome: .current), .init(id: "two", name: "Two", outcome: outcome)])
        #expect(!report.fullyChecked)
        #expect(!report.summary.contains("up to date"))
    }
    @Test func successfulChecksRequireAnOutcomeForEveryItem() {
        #expect(!ExtensionUpdateReport().fullyChecked)
        #expect(!ExtensionUpdateReport(status: .busy).fullyChecked)
        #expect(ExtensionUpdateReport(entries: [.init(id: "one", name: "One", outcome: .current)]).fullyChecked)
    }
}
