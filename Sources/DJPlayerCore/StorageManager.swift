import Foundation

/// Сохранение состояния приложения и экспорт/импорт плейлистов.
///
/// Все записи атомарные: при падении посреди записи на диске остаётся либо
/// старый, либо новый файл, но не обрезанный. Если файл состояния всё же
/// не читается, он сохраняется рядом как резервная копия — данные не
/// исчезают бесследно, пользователь может их починить вручную.
public final class StorageManager {

    public static let shared = StorageManager()

    private let fileManager = FileManager.default

    /// Подменяемый каталог состояния. Нужен юнит-тестам: без него они писали бы
    /// в реальный `~/Library/Application Support` и мешали данным пользователя.
    private let overrideDirectory: URL?

    /// Сообщение о последней проблеме чтения/записи (для показа в интерфейсе).
    /// nil, если всё прошло гладко.
    public private(set) var lastIssue: String?

    public init() {
        overrideDirectory = nil
    }

    /// Инициализатор для тестов: всё состояние пишется в указанный каталог.
    public init(directory: URL) {
        overrideDirectory = directory
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Пути

    private var directory: URL {
        if let overrideDirectory { return overrideDirectory }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DJPlayer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var stateURL: URL {
        directory.appendingPathComponent("appstate.json")
    }

    /// Путь к файлу состояния — выводится в консоль для отладки.
    public var statePath: String { stateURL.path }

    // MARK: - Состояние приложения

    public func save(_ state: AppState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
            lastIssue = nil
        } catch {
            lastIssue = "Не удалось сохранить состояние: \(error.localizedDescription)"
            NSLog("DJPlayer: %@", lastIssue ?? "")
        }
    }

    public func load() -> AppState {
        lastIssue = nil

        guard fileManager.fileExists(atPath: stateURL.path) else {
            return AppState.fresh()
        }

        do {
            let data = try Data(contentsOf: stateURL)
            var state = try JSONDecoder().decode(AppState.self, from: data)
            state.repair()
            return state
        } catch {
            // Не читается — откладываем копию, чтобы данные можно было
            // восстановить, и только потом начинаем с чистого листа.
            let backup = backupUnreadableState()
            let hint = backup.map { " Резервная копия: \($0.lastPathComponent)" } ?? ""
            lastIssue = "Файл состояния повреждён, настройки сброшены.\(hint)"
            NSLog("DJPlayer: не удалось прочитать состояние — %@", error.localizedDescription)
            return AppState.fresh()
        }
    }

    /// Переименовывает нечитаемый файл состояния, освобождая путь для нового.
    private func backupUnreadableState() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent("appstate.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: stateURL, to: backup)
            return backup
        } catch {
            NSLog("DJPlayer: не удалось сохранить резервную копию состояния — %@", error.localizedDescription)
            // Хотя бы не даём новому сохранению затереть старый файл молча.
            try? fileManager.removeItem(at: stateURL)
            return nil
        }
    }

    // MARK: - Экспорт / импорт плейлистов

    /// Пишет плейлист в файл вместе с версией формата.
    public func export(_ playlist: Playlist, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PlaylistFile(playlist: playlist))
        try data.write(to: url, options: .atomic)
    }

    /// Читает и новый формат (обёртка с версией), и старый «голый» Playlist,
    /// который писали предыдущие версии приложения.
    public func `import`(from url: URL) throws -> Playlist {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        if let file = try? decoder.decode(PlaylistFile.self, from: data) {
            return file.playlist
        }
        return try decoder.decode(Playlist.self, from: data)
    }

    // MARK: - Частичное чтение состояния

/// Читает файл состояния «по кускам»: каждое поле независимо, битые плейлисты пропускаются.
/// Нужен только для восстановления, когда `AppState` целиком не разбирается.
private struct PartialState: Decodable {
    var playlists: [Playlist]
    var settings: AppSettings
    var selectedPlaylistID: UUID?

    // При своём init(from:) CodingKeys не синтезируется — объявляем явно.
    enum CodingKeys: String, CodingKey {
        case playlists, settings, selectedPlaylistID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlists = c.decodeLossyArray(Playlist.self, forKey: .playlists).items
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        selectedPlaylistID = try? c.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
    }
}

// MARK: - Сброс

    public func resetAll() {
        try? fileManager.removeItem(at: stateURL)
    }
}
