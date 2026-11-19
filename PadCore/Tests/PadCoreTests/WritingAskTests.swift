import XCTest
@testable import PadCore

final class WritingAskTests: XCTestCase {
    /// The table from the task: a welcome in progress asks on its own step,
    /// a done welcome leaves the small sheet to ask, and once the flag is
    /// set nothing ever asks again.
    func testTheDecisionFollowsTheWelcomeAndTheFlag() {
        XCTAssertEqual(WritingAsk.decision(welcomePending: true, asked: false), .welcomeStep)
        XCTAssertEqual(WritingAsk.decision(welcomePending: false, asked: false), .sheet)
        XCTAssertEqual(WritingAsk.decision(welcomePending: false, asked: true), .nothing)
        XCTAssertEqual(WritingAsk.decision(welcomePending: true, asked: true), .nothing)
    }

    func testSkipSetupDeclinesTheLaterOfferEvenWithoutAWritingAnswer() throws {
        var progress = SetupProgress(step: .space, spaceID: UUID())
        progress.complete(.skipped)
        let restored = try XCTUnwrap(SetupProgress.restore(data: try JSONEncoder().encode(progress), legacyState: "done"))
        for asked in [false, true] {
            XCTAssertEqual(WritingAsk.decision(welcomePending: restored.isPending, asked: asked,
                                              setupSkipped: restored.completion == .skipped), .nothing)
        }
    }

    func testExistingUsersKeepTheirOnceOnlyUpgradeOffer() {
        let upgraded = SetupProgress.restore(data: nil, legacyState: "done")
        XCTAssertEqual(WritingAsk.decision(welcomePending: upgraded?.isPending == true, asked: false,
                                          setupSkipped: upgraded?.completion == .skipped), .sheet)
        XCTAssertEqual(WritingAsk.decision(welcomePending: false, asked: true), .nothing)
        XCTAssertEqual(WritingAsk.decision(welcomePending: false, asked: false), .sheet)
    }
}
