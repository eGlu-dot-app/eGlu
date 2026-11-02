import XCTest
@testable import PadCore

final class PicturePreferenceTests: XCTestCase {
    func testAutomaticPictureDefaultsToOnForNewAndExistingSettings() throws {
        XCTAssertTrue(Preferences().automaticPictureInPicture)
        for saved in ["{}", #"{"automaticPictureInPicture":null}"#, #"{"automaticPictureInPicture":"unknown"}"#] {
            let preferences = try JSONDecoder().decode(Preferences.self, from: Data(saved.utf8))
            XCTAssertTrue(preferences.automaticPictureInPicture)
        }
    }

    func testAutomaticPictureChoiceSurvivesSaving() throws {
        for enabled in [true, false] {
            var preferences = Preferences()
            preferences.automaticPictureInPicture = enabled
            let data = try JSONEncoder().encode(preferences)
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
        }
    }
}

final class WritingPreferenceTests: XCTestCase {
    func testTheWritingOtherAppsSettingsDefaultToOff() throws {
        let old = try XCTUnwrap(#"{"writing":true}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertFalse(preferences.writingOtherApps)
        XCTAssertEqual(preferences.writingApps, [:])
        XCTAssertFalse(preferences.writingNewApps)
    }

    func testTheWritingOtherAppsSettingsRoundTrip() throws {
        var preferences = Preferences()
        preferences.writingOtherApps = true
        preferences.writingApps = ["com.apple.TextEdit": false, "com.example.any": true]
        preferences.writingNewApps = true
        let data = try JSONEncoder().encode(preferences)
        let read = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(read, preferences)
    }
}
