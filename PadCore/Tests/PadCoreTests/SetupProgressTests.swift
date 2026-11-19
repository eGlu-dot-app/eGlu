import Foundation
import Testing
@testable import PadCore

struct SetupProgressTests {
    @Test
    func testEveryStepSurvivesRelaunchAndKeepsTheOriginalSpace() throws {
        let original = UUID(), otherWindow = UUID()
        for step in SetupProgress.Step.allCases {
            let saved = SetupProgress(step: step, spaceID: original)
            let data = try JSONEncoder().encode(saved)
            let restored = try #require(SetupProgress.restore(data: data, legacyState: "pending"))
            let resumed = try #require(restored.resuming(spaceIDs: [otherWindow, original],
                                                         preferredSpaceID: otherWindow, asksWriting: true))
            #expect(resumed.step == step)
            #expect(resumed.spaceID == original)
            #expect(resumed.isPending)
        }
    }

    @Test func testBackNavigationBecomesTheResumePoint() throws {
        var progress = SetupProgress(step: .bookmarks, spaceID: UUID())
        progress.visit(.space)
        let restored = SetupProgress.restore(data: try JSONEncoder().encode(progress), legacyState: "pending")
        #expect(restored?.step == .space)
    }

    @Test func testUnavailableOrAlreadyAnsweredWritingFallsForward() throws {
        let space = UUID()
        let progress = SetupProgress(step: .writing, spaceID: space)
        let resumed = try #require(progress.resuming(spaceIDs: [space], preferredSpaceID: space, asksWriting: false))
        #expect(resumed.step == .finish)
        #expect(!SetupProgress.Step.offered(asksWriting: false).contains(.writing))
        #expect(SetupProgress.Step.offered(asksWriting: false).count == 4)
        #expect(SetupProgress.Step.offered(asksWriting: true).count == 5)
    }

    @Test func testDeletedSpaceFallsBackToALiveDestination() throws {
        let deleted = UUID(), current = UUID(), first = UUID()
        let progress = SetupProgress(step: .bookmarks, spaceID: deleted)
        #expect(progress.resuming(spaceIDs: [first, current], preferredSpaceID: current,
                                  asksWriting: true)?.spaceID == current)
        let fallback = try #require(progress.resuming(spaceIDs: [first], preferredSpaceID: deleted, asksWriting: true))
        #expect(fallback.spaceID == first)
        #expect(fallback.step == .bookmarks)
        #expect(progress.resuming(spaceIDs: [], preferredSpaceID: deleted, asksWriting: true) == nil)
    }

    @Test func testLegacyPendingBindsToTheFirstWelcomeWindow() throws {
        let space = UUID()
        let legacy = try #require(SetupProgress.restore(data: nil, legacyState: "pending"))
        #expect(legacy.isPending)
        #expect(legacy.step == .hello)
        #expect(legacy.spaceID == nil)
        #expect(legacy.resuming(spaceIDs: [space], preferredSpaceID: space, asksWriting: true)?.spaceID == space)
    }

    @Test func testLegacyDoneAndExistingWorkspacesNeverRestartSetup() throws {
        let done = try #require(SetupProgress.restore(data: nil, legacyState: "done"))
        #expect(done.completion == .completed)
        #expect(!done.isPending)
        #expect(done.resuming(spaceIDs: [UUID()], preferredSpaceID: UUID(), asksWriting: true) == nil)
        #expect(SetupProgress.restore(data: nil, legacyState: nil) == nil)
        #expect(SetupProgress.restore(data: nil, legacyState: "unknown") == nil)
    }

    @Test func testCorruptAndFutureRecordsRespectTheLegacyCompletionMarker() throws {
        let corrupt = Data("not json".utf8)
        let future = Data(#"{"version":2,"step":"hello"}"#.utf8)
        let unknownStep = Data(#"{"version":1,"step":"future-step"}"#.utf8)
        for data in [corrupt, future, unknownStep] {
            #expect(SetupProgress.restore(data: data, legacyState: "done")?.completion == .completed)
            #expect(SetupProgress.restore(data: data, legacyState: "pending")?.step == .hello)
            #expect(SetupProgress.restore(data: data, legacyState: nil) == nil)
        }
        let stale = try JSONEncoder().encode(SetupProgress(step: .space))
        #expect(try #require(SetupProgress.restore(data: stale, legacyState: "done")).isPending == false)
    }

    @Test func testCompletionReasonsSurviveAndCannotBeReopenedByNavigation() throws {
        for reason in [SetupProgress.Completion.completed, .skipped] {
            var progress = SetupProgress(step: .bookmarks, spaceID: UUID())
            progress.complete(reason)
            progress.visit(.hello)
            progress.complete(reason == .skipped ? .completed : .skipped)
            let restored = try #require(SetupProgress.restore(data: try JSONEncoder().encode(progress), legacyState: "done"))
            #expect(restored.completion == reason)
            #expect(restored.step == .bookmarks)
            #expect(!restored.isPending)
        }
    }
}
