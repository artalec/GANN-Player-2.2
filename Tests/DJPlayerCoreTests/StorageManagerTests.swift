import XCTest
@testable import DJPlayerCore

/// Тесты файлового слоя: миграция старого состояния, резервные копии
/// повреждённых файлов и совместимость формата экспорта.
///
/// Все тесты пишут во временный каталог, а не в реальный
/// `~/Library/Application Support`, поэтому не трогают данные пользователя.
final class StorageManagerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJPlayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeStorage() -> StorageManager {
        StorageManager(directory: directory)
    }

    // MARK: - Сохранение и чтение

    func testSaveThenLoadRoundTrips() {
        let storage = makeStorage()

        var state = AppState.fresh()
        state.playlists[0].name = "Сет на вечер"
        state.playlists[0].tracks = [
            Track(name: "Intro", path: "/Music/intro.mp3", duration: 180),
            Track(name: "Drop", path: "/Music/drop.flac", duration: 240,
                  color: RGBAColor.palette[1], trimStart: 15, trimEnd: 200)
        ]
        state.settings.volume = 0.65
        state.settings.crossfadeEnabled = true

        storage.save(state)
        XCTAssertNil(storage.lastIssue)

        let loaded = storage.load()
        XCTAssertNil(storage.lastIssue)
        XCTAssertEqual(loaded.playlists.count, 1)
        XCTAssertEqual(loaded.playlists[0].name, "Сет на вечер")
        XCTAssertEqual(loaded.playlists[0].tracks.count, 2)
        XCTAssertEqual(loaded.playlists[0].tracks[1].trimStart, 15, accuracy: 0.0001)
        XCTAssertEqual(loaded.settings.volume, 0.65, accuracy: 0.0001)
        XCTAssertTrue(loaded.settings.crossfadeEnabled)
    }

    func testLoadWithoutFileReturnsFreshState() {
        let storage = makeStorage()
        let state = storage.load()

        XCTAssertNil(storage.lastIssue)
        XCTAssertEqual(state.playlists.count, 1)
        XCTAssertNotNil(state.selectedPlaylistID)
    }

    /// Состояние, записанное версией приложения без schemaVersion и без
    /// loopEnabled/autoplayEnabled, должно читаться, а не сбрасываться.
    func testLegacyStateFileIsMigratedNotDiscarded() throws {
        let storage = makeStorage()
        let legacy = """
        {
          "playlists" : [
            {
              "id" : "11111111-1111-1111-1111-111111111111",
              "name" : "Старый плейлист",
              "order" : 0,
              "color" : { "red" : 0.2, "green" : 0.55, "blue" : 1, "alpha" : 1 },
              "tracks" : [
                { "id" : "22222222-2222-2222-2222-222222222222",
                  "name" : "Old Track", "path" : "/Music/old.mp3" }
              ]
            }
          ],
          "settings" : { "volume" : 0.9 },
          "selectedPlaylistID" : "11111111-1111-1111-1111-111111111111"
        }
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("appstate.json"))

        let state = storage.load()

        XCTAssertNil(storage.lastIssue, "Старый файл — не ошибка, он должен мигрировать молча")
        XCTAssertEqual(state.playlists.count, 1)
        XCTAssertEqual(state.playlists[0].name, "Старый плейлист")
        XCTAssertEqual(state.playlists[0].tracks.first?.name, "Old Track")
        XCTAssertEqual(state.settings.volume, 0.9, accuracy: 0.0001)
        XCTAssertEqual(state.schemaVersion, AppState.currentSchemaVersion)

        // После первого сохранения файл уже в новом формате.
        storage.save(state)
        XCTAssertEqual(try savedSchemaVersion(using: storage), AppState.currentSchemaVersion)
    }

    // MARK: - Повреждённый файл

    func testCorruptStateIsBackedUpAndReported() throws {
        let storage = makeStorage()
        let stateURL = directory.appendingPathComponent("appstate.json")
        try Data("{ это не json".utf8).write(to: stateURL)

        let state = storage.load()

        XCTAssertEqual(state.playlists.count, 1, "Вместо потери данных — чистое состояние")
        let issue = try XCTUnwrap(storage.lastIssue)
        XCTAssertTrue(issue.contains("повреждён"), "Пользователю нужно объяснить, что произошло: \(issue)")
        XCTAssertTrue(issue.contains("Резервная копия"),
                      "В сообщении должен быть путь к копии, иначе данные не найти")

        // Исходный файл не удалён безвозвратно: рядом лежит копия с тем же содержимым.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backups = files.filter { $0.hasPrefix("appstate.corrupt-") }
        XCTAssertEqual(backups.count, 1, "Должна остаться ровно одна резервная копия, файлы: \(files)")

        let backupData = try Data(contentsOf: directory.appendingPathComponent(backups[0]))
        XCTAssertEqual(String(decoding: backupData, as: UTF8.self), "{ это не json",
                       "Копия должна содержать исходные байты, а не перезаписанный файл")
    }

    func testEmptyStateFileIsTreatedAsCorrupt() throws {
        let storage = makeStorage()
        // Пустой файл — типичный результат аварийного завершения при записи.
        try Data().write(to: directory.appendingPathComponent("appstate.json"))

        _ = storage.load()

        XCTAssertNotNil(storage.lastIssue)
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("appstate.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - Экспорт / импорт

    func testExportedPlaylistImportsBack() throws {
        let storage = makeStorage()
        let playlist = Playlist(
            name: "Экспорт",
            tracks: [Track(name: "A", path: "/a.mp3", duration: 120, trimStart: 5)],
            color: RGBAColor.palette[4],
            order: 2,
            loopEnabled: true,
            autoplayEnabled: false
        )
        let url = directory.appendingPathComponent("set.djplaylist.json")

        try storage.export(playlist, to: url)
        let restored = try storage.import(from: url)

        XCTAssertEqual(restored, playlist)
        XCTAssertTrue(restored.loopEnabled, "Флаги плейлиста должны пережить экспорт")
        XCTAssertFalse(restored.autoplayEnabled)
    }

    /// Файлы, сохранённые предыдущей версией, — «голый» Playlist без обёртки.
    func testLegacyPlaylistFileWithoutEnvelopeImports() throws {
        let storage = makeStorage()
        let url = directory.appendingPathComponent("old.djplaylist.json")
        try Data("""
        {
          "id" : "33333333-3333-3333-3333-333333333333",
          "name" : "Старый файл",
          "order" : 1,
          "color" : { "red" : 0.1, "green" : 0.8, "blue" : 0.45, "alpha" : 1 },
          "tracks" : []
        }
        """.utf8).write(to: url)

        let restored = try storage.import(from: url)

        XCTAssertEqual(restored.name, "Старый файл")
        XCTAssertTrue(restored.autoplayEnabled, "Значение по умолчанию для нового поля")
        XCTAssertFalse(restored.loopEnabled)
    }

    func testImportOfBrokenFileThrows() throws {
        let storage = makeStorage()
        let url = directory.appendingPathComponent("broken.json")
        try Data("{ мусор".utf8).write(to: url)

        XCTAssertThrowsError(try storage.import(from: url))
    }

    // MARK: - Вспомогательное

    private func savedSchemaVersion(using storage: StorageManager) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: storage.statePath))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(json["schemaVersion"] as? Int)
    }
}
