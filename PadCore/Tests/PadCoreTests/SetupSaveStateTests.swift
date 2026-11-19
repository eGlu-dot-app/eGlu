import XCTest
@testable import PadCore

final class SetupSaveStateTests: XCTestCase {
    func testRejectedSkipKeepsItsIntentThroughRetry() {
        var state = SetupSaveState()
        XCTAssertTrue(state.begin(.skipped))
        XCTAssertTrue(state.isSaving)
        XCTAssertFalse(state.begin(.completed), "A second activation must not submit another save")
        state.acknowledge(false)
        XCTAssertEqual(state.retryReason, .skipped)
        XCTAssertFalse(state.isSaving)
        XCTAssertTrue(state.begin(.completed))
        XCTAssertEqual(state, .saving(.skipped), "Retrying a rejected Skip must not change it into completion")
        state.acknowledge(true)
        XCTAssertEqual(state, .saved(.skipped))
        XCTAssertFalse(state.begin(.skipped))
    }

    func testCompletionStaysActionableAfterRepeatedSaveFailures() {
        var state = SetupSaveState()
        for _ in 0..<3 {
            XCTAssertTrue(state.begin(.completed))
            state.acknowledge(false)
            XCTAssertEqual(state.retryReason, .completed)
        }
        XCTAssertTrue(state.begin(.completed))
        state.acknowledge(true)
        XCTAssertEqual(state, .saved(.completed))
        XCTAssertNil(state.retryReason)
    }

    func testUnsolicitedAcknowledgementCannotFinishSetup() {
        var state = SetupSaveState()
        state.acknowledge(true)
        XCTAssertEqual(state, .idle)
        state.begin(.completed)
        state.acknowledge(false)
        state.acknowledge(true)
        XCTAssertEqual(state, .failed(.completed), "A background save cannot dismiss setup without retrying the exit")
    }

    func testImportFailureAndRecoveryHaveOneActionAtEachStage() {
        func action(_ outcome: BookmarkImportOutcome?, destination: Bool = false, working: Bool = false) -> SetupBookmarkAction {
            .resolve(outcome: outcome, working: working, hasDestination: destination)
        }
        let parsed = BookmarkFile.parse(Data("<DL><DT><A HREF=\"https://example.com\">Example</A></DL>".utf8))
        XCTAssertEqual(action(nil), .chooseFile)
        for outcome in [BookmarkImportOutcome.cancelled, .empty, .unreadable, .archiveWithoutBookmarks, .workspaceUnavailable] {
            XCTAssertEqual(action(outcome), .chooseFile)
        }
        XCTAssertEqual(action(.destinationMissing(parsed)), .chooseDestination)
        XCTAssertEqual(action(.destinationMissing(parsed), destination: true), .importSelected)
        let complete = BookmarkImportOutcome.imported(added: 1, total: 1, space: "Client")
        XCTAssertEqual(action(complete.acknowledgingSave(false)), .retrySave)
        XCTAssertEqual(action(complete), .continueSetup)
        XCTAssertEqual(action(.duplicates(total: 1, space: "Client")), .continueSetup)
        XCTAssertEqual(action(complete, working: true), .wait, "Busy state wins over a stale success receipt")
        XCTAssertEqual(action(.destinationMissing(parsed), destination: true, working: true), .wait)
    }
}
