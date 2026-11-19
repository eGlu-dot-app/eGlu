import XCTest
@testable import PadCore

final class SettingsSearchTests: XCTestCase {
    private let all = SettingsSearch(anchors: SettingsAnchor.allCases)

    func testFindsAPartByItsNameOrByWhatIsChangedThere() {
        XCTAssertEqual(all.find("History").first?.anchor, .history)
        XCTAssertEqual(all.find("ad blocker").first?.anchor, .blocking)
        XCTAssertEqual(all.find("duckduckgo").first?.anchor, .search)
        XCTAssertEqual(all.find("pinned").first?.anchor, .pinnedTabs)
        XCTAssertEqual(all.find("plugin").first?.anchor, .extensions)
    }

    func testNothingTypedFindsNothing() {
        XCTAssertTrue(all.find("").isEmpty)
        XCTAssertTrue(all.find("   ").isEmpty)
    }

    func testOneLetterFindsMoreThanTheAddressBarsTwoRows() {
        XCTAssertGreaterThan(all.find("s").count, Autocomplete.settingLimit)
    }

    func testNoPartForWhatNothingIsCalled() {
        XCTAssertTrue(all.find("zzqxv").isEmpty)
        XCTAssertTrue(all.find(String(repeating: "x", count: 80)).isEmpty)
    }

    func testFindsOnlyThePartsItWasGiven() {
        let mac = SettingsSearch(anchors: [.appIcon, .history])
        XCTAssertEqual(mac.find("trackpad").map(\.anchor), [])
        XCTAssertEqual(Set(mac.find("i").map(\.anchor)).isSubset(of: [.appIcon, .history]), true)
    }

    func testAPartKeepsTheNamesItIsGiven() {
        let dock = SettingsSearch([.init(.appIcon, title: "App Icon", detail: "The icon in the Dock", keywords: ["dock icon"])])
        let found = dock.find("dock icon")
        XCTAssertEqual(found.map(\.title), ["App Icon"])
        XCTAssertEqual(found.first?.detail, "The icon in the Dock")
    }

    func testTheCommandBarsRowsGoWhereSettingsSearchGoes() {
        for candidate in all.candidates {
            guard case .setting(let anchor) = candidate.action else { return XCTFail("\(candidate.id) is not a setting") }
            XCTAssertEqual(candidate.source, .setting)
            XCTAssertEqual(candidate.id, "setting-\(anchor.rawValue)")
            XCTAssertEqual(candidate.title, anchor.title)
        }
        XCTAssertEqual(all.candidates.count, SettingsAnchor.allCases.count)
    }

    func testTheMacsOwnPanesAreNotOnTheIPhoneOrIPad() {
        for anchor in [SettingsAnchor.pinnedTabs, .extensions] {
            for phone in [false, true] {
                XCTAssertFalse(anchor.isOffered(phone: phone))
            }
            XCTAssertFalse(anchor.isOffered(phoneLayout: true, padLayout: true))
        }
    }

    func testEveryPartHasANameAndWordsToFindItBy() {
        for anchor in SettingsAnchor.allCases {
            XCTAssertFalse(anchor.title.isEmpty, "\(anchor)")
            XCTAssertFalse(anchor.detail.isEmpty, "\(anchor)")
            XCTAssertFalse(anchor.keywords.isEmpty, "\(anchor)")
            XCTAssertEqual(all.find(anchor.title).first?.anchor, anchor, "\(anchor) by its own name")
        }
    }
}
