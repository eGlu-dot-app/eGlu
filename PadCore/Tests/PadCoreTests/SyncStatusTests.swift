import Foundation
import XCTest
@testable import PadCore

final class SyncStatusTests: XCTestCase {
    func testResultAnnouncementsIgnorePollingAndTransientWork() {
        var announcements = SyncResultAnnouncements()
        XCTAssertFalse(announcements.accepts(.checkingAccount))
        XCTAssertFalse(announcements.accepts(.syncing))
        XCTAssertFalse(announcements.accepts(.waiting(.confirmation)))
        XCTAssertFalse(announcements.accepts(.waiting(.pendingChanges)))
        XCTAssertTrue(announcements.accepts(.waiting(.connection)))
        XCTAssertFalse(announcements.accepts(.retrying))
        XCTAssertFalse(announcements.accepts(.waiting(.connection)), "Network polling must not repeat the same warning")
        XCTAssertTrue(announcements.accepts(.completed))
        XCTAssertFalse(announcements.accepts(.syncing))
        XCTAssertFalse(announcements.accepts(.completed), "Another unchanged fetch is not a new result")
        XCTAssertTrue(announcements.accepts(.waiting(.error)))
        XCTAssertTrue(announcements.accepts(.completed), "Recovery after an error is a meaningful result")
    }

    func testNewlyEnabledSyncCanAnnounceTheSameAccountProblem() {
        var announcements = SyncResultAnnouncements()
        XCTAssertTrue(announcements.accepts(.waiting(.account)))
        XCTAssertFalse(announcements.accepts(.off))
        XCTAssertFalse(announcements.accepts(.checkingAccount))
        XCTAssertTrue(announcements.accepts(.waiting(.account)))
    }

    func testRelaunchRetainsHistoricalDateWithoutClaimingCurrentSync() {
        let previous = Date(timeIntervalSince1970: 10)
        var status = SyncStatus(lastSuccessfulSync: previous)
        status.start()
        XCTAssertEqual(status.phase, .checkingAccount)
        XCTAssertEqual(status.lastSuccessfulSync, previous)
        status.fetched(confirmed: false, pending: false, failed: false)
        XCTAssertEqual(status.phase, .waiting(.confirmation))
        XCTAssertEqual(status.lastSuccessfulSync, previous)
    }

    func testOfflineFailuresAndSendOnlyNeverBecomeCompleted() {
        var status = SyncStatus()
        status.start()
        status.wait(.connection)
        status.beginWork()
        XCTAssertEqual(status.phase, .retrying)
        status.wait(.service)
        status.fetched(confirmed: true, pending: false, failed: true)
        XCTAssertEqual(status.phase, .waiting(.service))
        XCTAssertNil(status.lastSuccessfulSync)
        XCTAssertFalse(status.sent(changed: true, pending: false, failed: true))
        XCTAssertEqual(status.phase, .waiting(.service))
        XCTAssertTrue(status.sent(changed: true, pending: false, failed: false))
        XCTAssertEqual(status.phase, .waiting(.confirmation))
        XCTAssertNil(status.lastSuccessfulSync)
    }

    func testUnrelatedZoneFetchDoesNotLeaveStatusSpinningOrInventANewConfirmation() {
        var status = SyncStatus()
        let confirmed = Date(timeIntervalSince1970: 20)
        status.fetched(confirmed: true, pending: false, failed: false, now: confirmed)
        status.beginWork()
        status.fetched(confirmed: false, pending: false, failed: false, now: confirmed.addingTimeInterval(10))
        XCTAssertEqual(status.phase, .completed)
        XCTAssertEqual(status.lastSuccessfulSync, confirmed)
        status.beginWork()
        status.fetched(confirmed: false, pending: true, failed: false)
        XCTAssertEqual(status.phase, .waiting(.pendingChanges))
    }

    func testSuccessfulRoundtripRequiresConfirmedReadAndNoPendingChanges() {
        var status = SyncStatus()
        let confirmed = Date(timeIntervalSince1970: 20)
        status.start()
        status.fetched(confirmed: true, pending: true, failed: false, now: confirmed)
        XCTAssertEqual(status.phase, .waiting(.pendingChanges))
        XCTAssertNil(status.lastSuccessfulSync)
        XCTAssertTrue(status.sent(changed: true, pending: false, failed: false))
        status.fetched(confirmed: true, pending: false, failed: false, now: confirmed)
        XCTAssertEqual(status.phase, .completed)
        XCTAssertEqual(status.lastSuccessfulSync, confirmed)
        status.changed()
        XCTAssertEqual(status.phase, .waiting(.pendingChanges))
        XCTAssertEqual(status.lastSuccessfulSync, confirmed)
        status.stop()
        XCTAssertEqual(status.phase, .off)
        XCTAssertEqual(status.lastSuccessfulSync, confirmed)
    }
}
