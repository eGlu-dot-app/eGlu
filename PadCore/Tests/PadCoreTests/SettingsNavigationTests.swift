import Testing
@testable import PadCore

@Suite("Adaptive Settings navigation")
struct SettingsNavigationTests {
    @Test func sidebarUsesThePresentedWidthAndNeverAppearsOnPhone() {
        #expect(!SettingsNavigation.usesSidebar(pad: true, width: 799))
        #expect(SettingsNavigation.usesSidebar(pad: true, width: 800))
        #expect(SettingsNavigation.usesSidebar(pad: true, width: 1000))
        #expect(!SettingsNavigation.usesSidebar(pad: false, width: 1000))
        #expect(!SettingsNavigation.usesSidebar(pad: true, width: 0))
    }

    @Test func wideDefaultsToGeneralButNarrowStartsAtCategories() {
        var navigation = SettingsNavigation()
        navigation.adapt(sidebar: false)
        #expect(navigation.path.isEmpty)
        navigation.adapt(sidebar: true)
        #expect(navigation.selection == .group(.general))
    }

    @Test func resizingPreservesEverySelectedPage() {
        let pages = SettingsGroup.allCases.map { SettingsNavigation.Page.group($0) } + [.acknowledgements]
        for page in pages {
            var navigation = SettingsNavigation()
            navigation.show(page)
            navigation.adapt(sidebar: false)
            #expect(navigation.path == [page])
            navigation.adapt(sidebar: true)
            #expect(navigation.path == [page])
        }
    }

    @Test func searchRevealSurvivesResizeAndAnotherSectionInTheSameGroup() {
        var navigation = SettingsNavigation()
        for anchor in [SettingsAnchor.history, .blocking, .appIcon] {
            navigation.reveal(anchor)
            let revealID = navigation.revealID
            navigation.adapt(sidebar: false)
            navigation.adapt(sidebar: true)
            #expect(navigation.selection == .group(anchor.group))
            #expect(navigation.anchor == anchor)
            #expect(navigation.revealID == revealID)
        }
    }

    @Test func categoryChoiceClearsSearchRevealAndBackReturnsToCategories() {
        var navigation = SettingsNavigation()
        navigation.reveal(.appIcon)
        navigation.show(.group(.privacy))
        #expect(navigation.anchor == nil)
        navigation.path = []
        #expect(navigation.selection == nil)
        navigation.adapt(sidebar: true)
        #expect(navigation.selection == .group(.general))
    }

    @Test func nativeStackBackClearsThePreviousSearchAnchor() {
        var navigation = SettingsNavigation()
        navigation.reveal(.appIcon)
        navigation.path = []
        #expect(navigation.anchor == nil)
        navigation.path = [.group(.general)]
        #expect(navigation.anchor == nil)
    }

    @Test func selectingTheSameResultCreatesANewRevealRequest() {
        var navigation = SettingsNavigation()
        navigation.reveal(.history)
        let first = navigation.revealID
        navigation.reveal(.history)
        #expect(navigation.anchor == .history)
        #expect(navigation.revealID != first)
        navigation.show(.group(.privacy))
        #expect(navigation.revealID == nil)
    }
}
