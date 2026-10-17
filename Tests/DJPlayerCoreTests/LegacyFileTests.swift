import XCTest
@testable import DJPlayerCore

/// Сверка с файлом состояния, который писал DJPlayer v25 (до появления schemaVersion,
/// loopEnabled и autoplayEnabled).
final class LegacyFileTests: XCTestCase {

    private let v25 = """
    {
      "playlists" : [
        {
          "color" : { "alpha" : 1, "blue" : 1, "green" : 0.55, "red" : 0.2 },
          "id" : "AAAAAAAA-0000-0000-0000-000000000001",
          "name" : "Плейлист 1",
          "order" : 0,
          "tracks" : [
            {
              "deleteAfterPlay" : false,
              "duration" : 245.5,
              "id" : "BBBBBBBB-0000-0000-0000-000000000001",
              "name" : "Track",
              "path" : "/Music/a.mp3",
              "trimStart" : 0
            }
          ]
        }
      ],
      "selectedPlaylistID" : "AAAAAAAA-0000-0000-0000-000000000001",
      "settings" : {
        "crossfadeDuration" : 3,
        "crossfadeEnabled" : false,
        "focusFadeDuration" : 1.5,
        "focusFadeEnabled" : false,
        "highCutDuration" : 2,
        "highCutEnabled" : false,
        "highCutPauseAfter" : 0,
        "loopTrackEnabled" : false,
        "volume" : 1
      }
    }
    """

    func testV25StateLoadsWithData() throws {
        var state = try JSONDecoder().decode(AppState.self, from: Data(v25.utf8))
        state.repair()

        XCTAssertEqual(state.playlists.count, 1)
        XCTAssertEqual(state.playlists[0].tracks.count, 1, "Трек не должен потеряться")
        XCTAssertEqual(state.playlists[0].tracks[0].duration, 245.5, accuracy: 0.01)
        XCTAssertFalse(state.playlists[0].loopEnabled)
        XCTAssertTrue(state.playlists[0].autoplayEnabled)
        XCTAssertEqual(state.selectedPlaylistID, state.playlists[0].id)
        XCTAssertEqual(state.schemaVersion, AppState.currentSchemaVersion)
    }
}
