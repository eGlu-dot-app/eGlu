import Foundation
import WebKitSupport
import XCTest

/// What can be checked of `WebKitStores` without making a store: a store is
/// a folder on disk under the running program's Library/WebKit, and WebKit
/// refuses to remove one while any object of it is alive, so a package test
/// would leave stores behind in the test runner's folder. Making stores, one
/// object per space, is checked in the app's own test host instead
/// (Tests/MacPage/PageEngineTests.swift and PageStorageTests.swift), whose
/// folder is its own.
final class WebKitStoresTests: XCTestCase {
    /// A space nothing has asked for has no store, and letting it go makes none.
    @MainActor
    func testForgetDoesNotMakeAnUnusedStore() {
        let space = UUID()
        XCTAssertFalse(WebKitStores.isMade(space))
        WebKitStores.forget(space)
        XCTAssertFalse(WebKitStores.isMade(space))
    }
}
