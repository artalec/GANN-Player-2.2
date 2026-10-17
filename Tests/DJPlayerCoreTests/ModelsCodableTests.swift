import XCTest
@testable import DJPlayerCore

/// Тесты формата хранения. Главная задача — гарантировать, что обновление
/// приложения не убивает сохранённые плейлисты пользователя.
final class ModelsCodableTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Playlist из файла предыдущей версии

    /// Ровно тот вид, который писала версия без loopEnabled/autoplayEnabled.
    private let legacyPlaylistJSON = """
    {
      "id" : "11111111-1111-1111-1111-111111111111",
      "name" : "Плейлист 1",
      "order" : 0,
      "color" : { "red" : 0.2, "green" : 0.55, "blue" : 1, "alpha" : 1 },
      "tracks" : [
        {
          "id" : "22222222-2222-2222-2222-222222222222",
          "name" : "Track One",
          "path" : "/Music/one.mp3"
        }
      ]
    }
    """

    func testPlaylistWithoutNewFieldsDecodesWithDefaults() throws {
        let playlist = try decode(Playlist.self, legacyPlaylistJSON)

        XCTAssertEqual(playlist.name, "Плейлист 1")
        XCTAssertEqual(playlist.tracks.count, 1)
        XCTAssertFalse(playlist.loopEnabled)
        XCTAssertTrue(playlist.autoplayEnabled, "Автопереход включён по умолчанию")
    }

    func testTrackWithoutOptionalFieldsDecodesWithDefaults() throws {
        let playlist = try decode(Playlist.self, legacyPlaylistJSON)
        let track = try XCTUnwrap(playlist.tracks.first)

        XCTAssertEqual(track.name, "Track One")
        XCTAssertNil(track.color)
        XCTAssertEqual(track.trimStart, 0)
        XCTAssertNil(track.trimEnd)
        XCTAssertFalse(track.deleteAfterPlay)
        XCTAssertEqual(track.duration, 0)
    }

    /// Главный регресс: состояние версии 1 целиком должно читаться.
    func testLegacyAppStateDecodesInsteadOfResetting() throws {
        let json = """
        {
          "playlists" : [ \(legacyPlaylistJSON) ],
          "settings" : { "volume" : 0.8, "crossfadeEnabled" : true },
          "selectedPlaylistID" : "11111111-1111-1111-1111-111111111111"
        }
        """

        var state = try decode(AppState.self, json)
        state.repair()

        XCTAssertEqual(state.schemaVersion, AppState.currentSchemaVersion)
        XCTAssertEqual(state.playlists.count, 1, "Плейлисты не должны теряться")
        XCTAssertEqual(state.playlists[0].tracks.count, 1)
        XCTAssertEqual(state.settings.volume, 0.8, accuracy: 0.0001)
        XCTAssertTrue(state.settings.crossfadeEnabled)
        XCTAssertEqual(state.selectedPlaylistID, state.playlists[0].id)
    }

    func testMissingSchemaVersionIsTreatedAsVersionOne() throws {
        let state = try decode(AppState.self, """
        { "playlists" : [], "settings" : {} }
        """)
        XCTAssertEqual(state.schemaVersion, 1)
    }

    // MARK: - Круговой обход

    func testAppStateRoundTrip() throws {
        var original = AppState.fresh()
        original.settings.crossfadeEnabled = true
        original.settings.crossfadeDuration = 7.5
        original.settings.volume = 0.42
        original.playlists[0].tracks = [
            Track(name: "A", path: "/a.mp3", duration: 100, trimStart: 10, trimEnd: 90),
            Track(name: "B", path: "/b.mp3", duration: 200, color: RGBAColor.palette[2],
                  deleteAfterPlay: true)
        ]
        original.playlists[0].loopEnabled = true
        original.playlists[0].autoplayEnabled = false
        original.selectedPlaylistID = original.playlists[0].id

        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(AppState.self, from: data)
        restored.repair()

        XCTAssertEqual(restored.playlists, original.playlists)
        XCTAssertEqual(restored.settings.volume, 0.42, accuracy: 0.0001)
        XCTAssertEqual(restored.settings.crossfadeDuration, 7.5, accuracy: 0.0001)
        XCTAssertEqual(restored.selectedPlaylistID, original.selectedPlaylistID)
        XCTAssertEqual(restored.schemaVersion, AppState.currentSchemaVersion)
    }

    func testPlaylistFileWrapsVersion() throws {
        let playlist = Playlist(name: "Set", order: 3)
        let data = try JSONEncoder().encode(PlaylistFile(playlist: playlist))

        let decoded = try JSONDecoder().decode(PlaylistFile.self, from: data)
        XCTAssertEqual(decoded.formatVersion, PlaylistFile.currentFormatVersion)
        XCTAssertEqual(decoded.playlist, playlist)
    }

    // MARK: - Санитизация

    func testTrimIsClampedAgainstDuration() throws {
        let track = Track(name: "X", path: "/x.mp3", duration: 60,
                          trimStart: 999, trimEnd: 999)
        XCTAssertLessThanOrEqual(track.trimStart, track.effectiveDuration + 60)
        XCTAssertNil(track.trimEnd, "Точка на конце файла хранится как nil")

        let negative = Track(name: "Y", path: "/y.mp3", duration: 60, trimStart: -5)
        XCTAssertEqual(negative.trimStart, 0)
    }

    func testEffectiveDurationNeverNegative() {
        let track = Track(name: "Z", path: "/z.mp3", duration: 10, trimStart: 10, trimEnd: 10)
        XCTAssertGreaterThanOrEqual(track.effectiveDuration, 0)
    }

    func testBrokenColorFallsBackToGray() throws {
        let color = try decode(RGBAColor.self, #"{ "red": null, "green": 5, "blue": -1 }"#)
        XCTAssertEqual(color.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(color.green, 1.0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.0001)
        XCTAssertEqual(color.alpha, 1.0, accuracy: 0.0001)
    }

    func testSettingsAreClampedToSliderRanges() throws {
        let settings = try decode(AppSettings.self, """
        { "volume" : 4.5, "crossfadeDuration" : 0.01, "highCutDuration" : 999,
          "focusFadeDuration" : -3, "highCutPauseAfter" : 42 }
        """)

        XCTAssertEqual(settings.volume, 1.0, accuracy: 0.0001)
        XCTAssertEqual(settings.crossfadeDuration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.highCutDuration, 10, accuracy: 0.0001)
        XCTAssertEqual(settings.focusFadeDuration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(settings.highCutPauseAfter, 10, accuracy: 0.0001)
    }

    // MARK: - Починка состояния

    func testRepairRestoresOrderAndSelection() {
        var state = AppState(
            playlists: [
                Playlist(name: "B", order: 7),
                Playlist(name: "A", order: 2)
            ],
            settings: AppSettings(),
            selectedPlaylistID: UUID()
        )
        state.repair()

        XCTAssertEqual(state.playlists.map(\.order), [0, 1])
        XCTAssertEqual(state.playlists[0].name, "A", "Сортировка по order сохранена")
        XCTAssertEqual(state.selectedPlaylistID, state.playlists[0].id,
                       "Несуществующий выбор заменяется первым плейлистом")
    }

    func testRepairCreatesPlaylistWhenNoneLeft() {
        var state = AppState(playlists: [], settings: AppSettings(), selectedPlaylistID: nil)
        state.repair()

        XCTAssertEqual(state.playlists.count, 1)
        XCTAssertNotNil(state.selectedPlaylistID)
    }

    func testDuplicateTrackPathsAreNotDeduplicatedByModel() {
        // Модель обязана сохранять то, что ей дали; дедупликация — дело
        // AppModel при добавлении файлов.
        let track = Track(name: "A", path: "/a.mp3")
        let playlist = Playlist(name: "P", tracks: [track, track])
        XCTAssertEqual(playlist.tracks.count, 2)
    }

    // MARK: - Щадящее декодирование

    /// Один битый трек не должен уносить весь плейлист, а вместе с ним и состояние.
    func testBrokenTrackDoesNotDropPlaylist() throws {
        let json = """
        {
          "id" : "33333333-3333-3333-3333-333333333333",
          "name" : "Живой",
          "order" : 0,
          "tracks" : [
            { "name" : "Good", "path" : "/good.mp3" },
            { "name" : "No path at all" },
            "совсем не объект"
          ]
        }
        """

        let playlist = try decode(Playlist.self, json)

        XCTAssertEqual(playlist.name, "Живой")
        XCTAssertEqual(playlist.tracks.count, 1, "Уцелел ровно один читаемый трек")
        XCTAssertEqual(playlist.tracks.first?.path, "/good.mp3")
    }

    /// Трек без id получает новый, а не выбрасывается: путь важнее идентификатора.
    func testTrackWithoutIDIsKept() throws {
        let playlist = try decode(Playlist.self, """
        { "name" : "P", "tracks" : [ { "name" : "NoId", "path" : "/x.mp3" } ] }
        """)

        XCTAssertEqual(playlist.tracks.count, 1)
        XCTAssertEqual(playlist.tracks.first?.name, "NoId")
    }

    /// Битый плейлист пропускается, остальные читаются — состояние не обнуляется.
    func testBrokenPlaylistDoesNotDropWholeState() throws {
        let json = """
        {
          "playlists" : [
            { "name" : "Первый", "order" : 0, "tracks" : [] },
            "это вообще не плейлист"
          ],
          "settings" : { "volume" : 0.5 }
        }
        """

        var state = try decode(AppState.self, json)
        state.repair()

        XCTAssertEqual(state.playlists.count, 1, "Читаемый плейлист должен остаться")
        XCTAssertEqual(state.playlists[0].name, "Первый")
        XCTAssertEqual(state.settings.volume, 0.5, accuracy: 0.0001)
    }

    /// Нечитаемый список треков обнуляет только его: сам плейлист остаётся.
    func testUnreadableTracksLeavePlaylistAlive() throws {
        let playlist = try decode(Playlist.self, """
        { "name" : "Живой", "tracks" : "это не массив" }
        """)

        XCTAssertEqual(playlist.name, "Живой")
        XCTAssertTrue(playlist.tracks.isEmpty)
    }

    /// Пустой или отсутствующий массив треков — это пустой список, а не ошибка.
    func testMissingTracksKeyIsEmptyNotError() throws {
        let playlist = try decode(Playlist.self, #"{ "name" : "Пусто" }"#)
        XCTAssertTrue(playlist.tracks.isEmpty)
    }
}

// MARK: - Переиспользование открытого файла

/// Правило из `AudioEngine.prepareSegment`: от него зависит, откроется ли файл заново.
/// Ошибка в одну сторону — лишнее открытие на каждой перемотке, в другую — чтение
/// уже закрытого файла.
final class FileReusePolicyTests: XCTestCase {

    func testSamePathIsReused() {
        XCTAssertTrue(FileReusePolicy.canReuse(openPath: "/Music/a.mp3",
                                               requestedPath: "/Music/a.mp3"))
    }

    func testDifferentFileIsNotReused() {
        XCTAssertFalse(FileReusePolicy.canReuse(openPath: "/Music/a.mp3",
                                                requestedPath: "/Music/b.mp3"))
    }

    func testNothingOpenMeansNoReuse() {
        XCTAssertFalse(FileReusePolicy.canReuse(openPath: nil, requestedPath: "/Music/a.mp3"))
    }

    /// Другой трек с тем же именем в другой папке — не тот же файл.
    func testSameNameInDifferentFolderIsNotReused() {
        XCTAssertFalse(FileReusePolicy.canReuse(openPath: "/Set A/track.mp3",
                                                requestedPath: "/Set B/track.mp3"))
    }

    /// Избыточные разделители и «..» не должны ломать сравнение.
    func testPathNormalisation() {
        XCTAssertTrue(FileReusePolicy.canReuse(openPath: "/Music//a.mp3",
                                               requestedPath: "/Music/a.mp3"))
        XCTAssertTrue(FileReusePolicy.canReuse(openPath: "/Music/Sub/../a.mp3",
                                               requestedPath: "/Music/a.mp3"))
    }
}

// MARK: - Учёт запросов waveform

/// Проверка сценария, из-за которого трек оставался без waveform навсегда:
/// выбран A → выбран B → снова выбран A, пока расчёт A ещё идёт.
final class WaveformRequestTrackerTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testNewRequestBecomesCurrent() {
        var tracker = WaveformRequestTracker()
        let r1 = UUID()
        tracker.begin(a, requestID: r1)

        XCTAssertTrue(tracker.isRunning(a))
        XCTAssertTrue(tracker.shouldApply(r1))
    }

    func testSwitchingTrackMakesPreviousRequestStale() {
        var tracker = WaveformRequestTracker()
        let r1 = UUID(), r2 = UUID()
        tracker.begin(a, requestID: r1)
        tracker.begin(b, requestID: r2)

        XCTAssertFalse(tracker.shouldApply(r1), "Расчёт A больше не актуален")
        XCTAssertTrue(tracker.shouldApply(r2))
    }

    /// Главный регресс: возврат к треку во время его расчёта.
    func testResumeMakesInFlightRequestCurrentAgain() {
        var tracker = WaveformRequestTracker()
        let r1 = UUID(), r2 = UUID()
        tracker.begin(a, requestID: r1)
        tracker.begin(b, requestID: r2)

        XCTAssertTrue(tracker.resume(a), "Расчёт A ещё идёт — новый запускать не нужно")
        XCTAssertTrue(tracker.shouldApply(r1), "Расчёт A снова актуален")
        XCTAssertFalse(tracker.shouldApply(r2))
    }

    func testResumeWithoutInFlightRequestReturnsFalse() {
        var tracker = WaveformRequestTracker()
        XCTAssertFalse(tracker.resume(a), "Считать нечего — нужен новый запрос")
    }

    func testFinishStopsTrackingTrack() {
        var tracker = WaveformRequestTracker()
        let r1 = UUID()
        tracker.begin(a, requestID: r1)
        tracker.finish(a)

        XCTAssertFalse(tracker.isRunning(a))
        XCTAssertFalse(tracker.resume(a))
    }

    func testSecondTrackCanKeepRunningWhileFirstIsCurrent() {
        var tracker = WaveformRequestTracker()
        let r1 = UUID(), r2 = UUID()
        tracker.begin(a, requestID: r1)
        tracker.begin(b, requestID: r2)

        // Оба расчёта идут, но применяется только последний.
        XCTAssertTrue(tracker.isRunning(a), "A не отменён, просто неактуален")
        XCTAssertTrue(tracker.isRunning(b))
        XCTAssertTrue(tracker.shouldApply(r2))
    }
}

// MARK: - Сверка потерянного файла

/// Правило подмены пути. Ошибка здесь означает, что к чужому файлу применятся
/// сохранённые точки обрезки — то есть пользователь потеряет свою разметку.
final class RelinkPolicyTests: XCTestCase {

    private let hashA = "3f8a1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private let hashB = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testSameHashIsMatch() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: hashA, candidateHash: hashA), .match)
        XCTAssertTrue(RelinkPolicy.acceptsReplacement(.match))
    }

    /// Хэши записываются в нижнем регистре, но сравнивать их нужно без учёта регистра:
    /// иначе файл, найденный на диске с хэшем в другом регистре, не опознается.
    func testHashComparisonIsCaseInsensitive() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: hashA,
                                            candidateHash: hashA.uppercased()), .match)
    }

    func testDifferentHashIsRejected() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: hashA, candidateHash: hashB), .rejected)
        XCTAssertFalse(RelinkPolicy.acceptsReplacement(.rejected))
    }

    /// Главная защита: без хэша потерянного файла сверять нечем, и подмену не делаем.
    /// Иначе одноимённый файл получил бы чужие точки обрезки.
    func testMissingReferenceHashIsNotVerified() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: nil, candidateHash: hashA), .cannotVerify)
        XCTAssertFalse(RelinkPolicy.acceptsReplacement(.cannotVerify))
    }

    func testEmptyReferenceHashIsNotVerified() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: "", candidateHash: hashA), .cannotVerify)
    }

    func testUnreadableCandidateIsRejected() {
        XCTAssertEqual(RelinkPolicy.verdict(referenceHash: hashA, candidateHash: nil), .rejected)
    }
}

// MARK: - Новые поля Track: обратная совместимость

extension ModelsCodableTests {

    /// Файл состояния предыдущей версии не содержит contentHash, byteCount и
    /// recoveredFromSearch. Он обязан читаться: иначе обновление сотрёт плейлисты.
    func testTrackWithoutHashFieldsDecodes() throws {
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data("""
        {
          "name" : "P",
          "tracks" : [
            { "id" : "44444444-4444-4444-4444-444444444444",
              "name" : "Old", "path" : "/old.mp3", "duration" : 100 }
          ]
        }
        """.utf8))

        let track = try XCTUnwrap(playlist.tracks.first)
        XCTAssertNil(track.contentHash)
        XCTAssertNil(track.byteCount)
        XCTAssertFalse(track.recoveredFromSearch)
    }

    /// Новые поля должны пережить сохранение и чтение.
    func testHashFieldsSurviveRoundTrip() throws {
        let track = Track(name: "A", path: "/a.mp3", duration: 10,
                          contentHash: "abc123", byteCount: 4096,
                          recoveredFromSearch: true)

        let data = try JSONEncoder().encode(track)
        let restored = try JSONDecoder().decode(Track.self, from: data)

        XCTAssertEqual(restored.contentHash, "abc123")
        XCTAssertEqual(restored.byteCount, 4096)
        XCTAssertTrue(restored.recoveredFromSearch)
    }

    /// Позиция в списке и настройки привязаны к id, а не к пути: именно поэтому
    /// подмена path оставляет обрезку и цвет на месте.
    func testSettingsBelongToTrackIdentityNotPath() throws {
        var track = Track(name: "A", path: "/old/a.mp3", duration: 200,
                          color: RGBAColor.palette[3], trimStart: 30, trimEnd: 150,
                          deleteAfterPlay: true)
        let originalID = track.id

        track.path = "/new/a.mp3"

        XCTAssertEqual(track.id, originalID)
        XCTAssertEqual(track.trimStart, 30, accuracy: 0.0001)
        // trimEnd — опционал, поэтому сверяем через развёрнутое значение:
        // перегрузка XCTAssertEqual с точностью принимает только Double.
        XCTAssertEqual(try XCTUnwrap(track.trimEnd), 150, accuracy: 0.0001)
        XCTAssertEqual(track.color, RGBAColor.palette[3])
        XCTAssertTrue(track.deleteAfterPlay)
    }
}
