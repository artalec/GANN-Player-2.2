import Foundation

// MARK: - Щадящее декодирование массивов

/// Обёртка, которая никогда не роняет декодирование: если элемент испорчен,
/// получаем nil, но позиция в массиве сохраняется.
///
/// Нужна потому, что `decodeIfPresent([Track].self, ...)` падает целиком из-за
/// одного битого трека — и вместе с ним пропадает весь файл состояния со всеми
/// плейлистами. С обёрткой страдает только испорченная запись.
struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// Результат щадящего декодирования массива: что уцелело и сколько выкинули.
struct LossyArray<Element> {
    var items: [Element] = []
    var skipped = 0
}

extension KeyedDecodingContainer {

    /// Читает массив по ключу, пропуская нечитаемые элементы.
    /// Отсутствующий ключ или не-массив дают пустой результат, но не ошибку.
    func decodeLossyArray<Element: Decodable>(_ type: Element.Type,
                                              forKey key: Key) -> LossyArray<Element> {
        var result = LossyArray<Element>()
        // `try?` сам схлопывает Optional: отсутствующий ключ даёт nil, а не ошибку.
        guard let boxed = try? decodeIfPresent([Lossy<Element>].self, forKey: key) else {
            return result
        }
        result.items = boxed.compactMap(\.value)
        result.skipped = boxed.count - result.items.count
        return result
    }
}

// MARK: - Track

public struct Track: Identifiable, Codable, Hashable {

    public let id: UUID
    public var name: String
    public var path: String
    public var duration: TimeInterval

    public var color: RGBAColor?        // nil = цвет плейлиста
    public var trimStart: TimeInterval  // начало воспроизведения
    public var trimEnd: TimeInterval?   // nil = до конца файла
    public var deleteAfterPlay: Bool

    /// SHA-256 содержимого файла на момент, когда он был доступен.
    ///
    /// Нужен, чтобы после пропажи файла найти его копию на диске и убедиться, что это
    /// действительно он, а не одноимённый трек. Считается в фоне и хранится в файле
    /// состояния: без него сверка возможна только по имени и размеру.
    /// nil — хэш ещё не считан (например, трек добавлен до появления этой версии).
    public var contentHash: String?

    /// Размер файла в байтах на момент, когда он был доступен.
    ///
    /// Нужен только как дешёвый отсев: сравнивать мегабайты содержимого у заведомо
    /// неподходящих кандидатов незачем. Решение о подмене принимает хэш, не размер.
    public var byteCount: Int64?

    /// Путь был восстановлен автоматическим поиском, а не выбран пользователем.
    /// Отличает такие треки в списке значком © — чтобы было видно, что путь не тот,
    /// который указывали изначально.
    public var recoveredFromSearch: Bool

    public var url: URL { URL(fileURLWithPath: path) }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Длительность с учётом trim.
    public var effectiveDuration: TimeInterval {
        let end = trimEnd ?? duration
        return max(0, end - trimStart)
    }

    // MARK: Codable

    /// Декодер терпим к отсутствующим полям: файл состояния, записанный
    /// предыдущей версией приложения, не содержит новых ключей. Без этого
    /// любой апгрейд превращался бы в потерю всех плейлистов.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Без id трек не идентифицируем, но и терять его из-за одного битого ключа не стоит:
        // выдаём новый UUID, сам трек остаётся в плейлисте.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Без названия"
        path = try c.decode(String.self, forKey: .path)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        deleteAfterPlay = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterPlay) ?? false
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        byteCount = try c.decodeIfPresent(Int64.self, forKey: .byteCount)
        recoveredFromSearch = try c.decodeIfPresent(Bool.self, forKey: .recoveredFromSearch) ?? false
        sanitize()
    }

    // MARK: Init

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                duration: TimeInterval = 0,
                color: RGBAColor? = nil,
                trimStart: TimeInterval = 0,
                trimEnd: TimeInterval? = nil,
                deleteAfterPlay: Bool = false,
                contentHash: String? = nil,
                byteCount: Int64? = nil,
                recoveredFromSearch: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.duration = duration
        self.color = color
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.deleteAfterPlay = deleteAfterPlay
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.recoveredFromSearch = recoveredFromSearch
        sanitize()
    }

    public init(url: URL, duration: TimeInterval = 0) {
        self.init(name: url.deletingPathExtension().lastPathComponent,
                  path: url.standardizedFileURL.path,
                  duration: duration)
    }

    // MARK: Нормализация

    /// Приводит поля к согласованному виду. Вызывается после декодирования:
    /// битые или отредактированные вручную файлы не должны ронять движок.
    private mutating func sanitize() {
        if !duration.isFinite || duration < 0 { duration = 0 }

        if !trimStart.isFinite || trimStart < 0 { trimStart = 0 }

        if let end = trimEnd {
            if !end.isFinite || end <= 0 {
                trimEnd = nil
            } else if duration > 0 {
                let clamped = min(end, duration)
                // Точка, совпавшая с концом файла, хранится как nil.
                trimEnd = abs(clamped - duration) < 0.05 ? nil : clamped
            } else {
                trimEnd = end
            }
        }

        // trimStart не может выходить за пределы файла: без этого после
        // подмены файла на более короткий трек начинался бы с тишины.
        if duration > 0 {
            let upperBound = trimEnd.map { min($0, duration) } ?? duration
            if trimStart > upperBound {
                trimStart = max(0, upperBound - 0.1)
            }
        }

        if let end = trimEnd, trimStart >= end {
            trimStart = max(0, end - 0.1)
        }
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Codable, Hashable {

    public let id: UUID
    public var name: String
    public var tracks: [Track]
    public var color: RGBAColor
    public var order: Int

    public var loopEnabled: Bool
    public var autoplayEnabled: Bool

    // MARK: Codable

    /// Как и у Track: отсутствующие ключи получают значения по умолчанию.
    /// Раньше синтезированный декодер требовал ВСЕ поля, поэтому плейлист
    /// из старого appstate.json не читался и состояние молча сбрасывалось.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Плейлист"
        // Битый трек (например, потерянный path) не должен уносить весь плейлист:
        // пропускаем только его и запоминаем, сколько выкинули.
        let decodedTracks = c.decodeLossyArray(Track.self, forKey: .tracks)
        tracks = decodedTracks.items
        if decodedTracks.skipped > 0 {
            NSLog("DJPlayer: в плейлисте «%@» пропущено треков: %d",
                  name, decodedTracks.skipped)
        }
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
            ?? RGBAColor(red: 0.20, green: 0.55, blue: 1.0)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        autoplayEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoplayEnabled) ?? true
    }

    // MARK: Init

    public init(id: UUID = UUID(),
                name: String,
                tracks: [Track] = [],
                color: RGBAColor = RGBAColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1.0),
                order: Int = 0,
                loopEnabled: Bool = false,
                autoplayEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.color = color
        self.order = order
        self.loopEnabled = loopEnabled
        self.autoplayEnabled = autoplayEnabled
    }
}

// MARK: - Codable color

public struct RGBAColor: Codable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Декодер терпим к неполным и битым значениям: цвет не стоит того,
    /// чтобы из-за него терять весь плейлист.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .red) ?? 0.5)
        green = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .green) ?? 0.5)
        blue = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0.5)
        alpha = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 1.0)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    public static let palette: [RGBAColor] = [
        RGBAColor(red: 0.20, green: 0.55, blue: 1.00),
        RGBAColor(red: 1.00, green: 0.27, blue: 0.35),
        RGBAColor(red: 0.15, green: 0.80, blue: 0.45),
        RGBAColor(red: 1.00, green: 0.65, blue: 0.10),
        RGBAColor(red: 0.65, green: 0.35, blue: 0.95),
        RGBAColor(red: 0.10, green: 0.75, blue: 0.85),
        RGBAColor(red: 0.95, green: 0.45, blue: 0.75),
        RGBAColor(red: 0.40, green: 0.40, blue: 0.40),
        RGBAColor(red: 0.95, green: 0.95, blue: 0.20),
        RGBAColor(red: 0.85, green: 0.45, blue: 0.25)
    ]
}

// MARK: - Settings

public struct AppSettings: Codable {
    public var crossfadeEnabled: Bool = false
    public var crossfadeDuration: Double = 3.0
    public var highCutEnabled: Bool = false
    public var highCutDuration: Double = 2.0
    public var highCutPauseAfter: Double = 0.0
    public var volume: Double = 1.0
    public var loopTrackEnabled: Bool = false
    public var focusFadeEnabled: Bool = false
    public var focusFadeDuration: Double = 1.5

    public init() {}

    public init(crossfadeEnabled: Bool,
                crossfadeDuration: Double,
                highCutEnabled: Bool,
                highCutDuration: Double,
                highCutPauseAfter: Double = 0.0,
                volume: Double = 1.0) {
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.highCutEnabled = highCutEnabled
        self.highCutDuration = highCutDuration
        self.highCutPauseAfter = highCutPauseAfter
        self.volume = volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 3.0
        highCutEnabled = try c.decodeIfPresent(Bool.self, forKey: .highCutEnabled) ?? false
        highCutDuration = try c.decodeIfPresent(Double.self, forKey: .highCutDuration) ?? 2.0
        highCutPauseAfter = try c.decodeIfPresent(Double.self, forKey: .highCutPauseAfter) ?? 0.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        loopTrackEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopTrackEnabled) ?? false
        focusFadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusFadeEnabled) ?? false
        focusFadeDuration = try c.decodeIfPresent(Double.self, forKey: .focusFadeDuration) ?? 1.5

        // Диапазоны совпадают с ползунками в интерфейсе.
        crossfadeDuration = clamp(crossfadeDuration, 0.5, 15, fallback: 3.0)
        highCutDuration = clamp(highCutDuration, 0.3, 10, fallback: 2.0)
        highCutPauseAfter = clamp(highCutPauseAfter, 0, 10, fallback: 0)
        focusFadeDuration = clamp(focusFadeDuration, 0.2, 10, fallback: 1.5)
        volume = clamp(volume, 0, 1, fallback: 1.0)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, lower), upper)
    }
}

// MARK: - Persisted application state

public struct AppState: Codable {

    /// Версия формата файла состояния. Растёт при несовместимых изменениях,
    /// чтобы будущие версии могли мигрировать данные, а не терять их.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var playlists: [Playlist]
    public var settings: AppSettings
    public var selectedPlaylistID: UUID?

    public init(schemaVersion: Int = AppState.currentSchemaVersion,
                playlists: [Playlist],
                settings: AppSettings,
                selectedPlaylistID: UUID?) {
        self.schemaVersion = schemaVersion
        self.playlists = playlists
        self.settings = settings
        self.selectedPlaylistID = selectedPlaylistID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Файлы версии 1 поля schemaVersion не содержат — считаем их версией 1.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Повреждённый плейлист не должен обнулять всё состояние: остальные читаются.
        let decodedPlaylists = c.decodeLossyArray(Playlist.self, forKey: .playlists)
        playlists = decodedPlaylists.items
        if decodedPlaylists.skipped > 0 {
            NSLog("DJPlayer: в файле состояния пропущено плейлистов: %d", decodedPlaylists.skipped)
        }
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        selectedPlaylistID = try c.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
    }

    public static func fresh() -> AppState {
        let first = Playlist(name: "Плейлист 1", order: 0)
        return AppState(playlists: [first], settings: AppSettings(), selectedPlaylistID: first.id)
    }

    /// Приводит состояние к валидному виду после загрузки: восстанавливает
    /// порядок плейлистов, чинит выбранный ID и пустой список.
    public mutating func repair() {
        if playlists.isEmpty {
            let first = Playlist(name: "Плейлист 1", order: 0)
            playlists = [first]
            selectedPlaylistID = first.id
            return
        }

        // Порядок должен быть перестановкой 0..<count, иначе сортировка
        // в интерфейсе ведёт себя непредсказуемо.
        playlists = playlists.sorted { $0.order < $1.order }
        for index in playlists.indices {
            playlists[index].order = index
        }

        if let id = selectedPlaylistID, !playlists.contains(where: { $0.id == id }) {
            selectedPlaylistID = playlists.first?.id
        }
        if selectedPlaylistID == nil {
            selectedPlaylistID = playlists.first?.id
        }

        schemaVersion = Self.currentSchemaVersion
    }
}

// MARK: - Playlist file envelope

/// Формат экспортируемого файла плейлиста.
///
/// Раньше наружу писался «голый» Playlist — тот же самый JSON, что и во
/// внутреннем состоянии. Добавление любого поля ломало импорт старых файлов.
/// Теперь у файла есть версия, а чтение понимает оба варианта.
public struct PlaylistFile: Codable {

    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var playlist: Playlist

    public init(formatVersion: Int = PlaylistFile.currentFormatVersion,
                playlist: Playlist) {
        self.formatVersion = formatVersion
        self.playlist = playlist
    }
}

// MARK: - Решение о переоткрытии файла

/// Правило «можно ли переиспользовать уже открытый файл», вынесенное из аудиодвижка.
///
/// Само решение — чистая функция от двух путей, поэтому его можно покрыть тестами
/// без AVFoundation: на Linux движок не собрать, а ошибка здесь означает либо
/// лишнее открытие файла на каждой перемотке, либо чтение уже закрытого файла.
public enum FileReusePolicy {

    /// Сравнивает пути с учётом символических ссылок и различий в записи.
    public static func canReuse(openPath: String?, requestedPath: String) -> Bool {
        guard let openPath else { return false }
        let a = URL(fileURLWithPath: openPath).standardizedFileURL.path
        let b = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        return a == b
    }
}

// MARK: - Учёт запросов на расчёт waveform

/// Отслеживает, какие расчёты пиков идут и какой из них актуален.
///
/// Вынесено из `AppModel`, потому что здесь была ошибка: «что считается» хранилось
/// множеством, а «чей расчёт актуален» — одним общим ID. Повторный выбор трека во время
/// его же расчёта не запускал новый запрос (трек уже в множестве) и не делал старый
/// актуальным — расчёт завершался отменённым, пики не кэшировались, и waveform этого
/// трека не появлялся уже никогда. Здесь оба факта живут в одном месте.
public struct WaveformRequestTracker {

    /// Актуальный запрос: единственный, чей результат будет применён.
    public private(set) var current: UUID?
    /// Запросы, которые ещё считаются, по ID трека.
    private var inFlight: [UUID: UUID] = [:]

    public init() {}

    /// Идёт ли расчёт для трека.
    public func isRunning(_ trackID: UUID) -> Bool {
        inFlight[trackID] != nil
    }

    /// Запрос, идущий для трека, если он есть.
    public func request(for trackID: UUID) -> UUID? {
        inFlight[trackID]
    }

    /// Регистрирует новый расчёт и делает его актуальным.
    public mutating func begin(_ trackID: UUID, requestID: UUID) {
        inFlight[trackID] = requestID
        current = requestID
    }

    /// Делает уже идущий расчёт актуальным снова.
    ///
    /// Возвращает false, если для трека ничего не считается: тогда нужен новый запрос.
    @discardableResult
    public mutating func resume(_ trackID: UUID) -> Bool {
        guard let running = inFlight[trackID] else { return false }
        current = running
        return true
    }

    /// Снимает расчёт с учёта. Вызывается по завершении, в том числе отменённого.
    public mutating func finish(_ trackID: UUID) {
        inFlight[trackID] = nil
    }

    /// Пора ли применять результат: он не отменён и относится к текущему запросу.
    public func shouldApply(_ requestID: UUID) -> Bool {
        current == requestID
    }
}

// MARK: - Поиск потерянного файла

/// Решает, является ли найденный файл той же самой записью, что и потерянная.
///
/// Правило намеренно строгое: подменять трек похожим файлом нельзя, потому что
/// к нему применяются сохранённые настройки — точки обрезки, цвет, «удалить после
/// проигрывания». Обрезка привязана к времени *этого* аудио: если подставить файл
/// другой длины или другой записи, пользователь получит не тот фрагмент, который
/// настраивал. Поэтому решает только совпадение хэша содержимого.
public enum RelinkPolicy {

    public enum Verdict: Equatable {
        /// Хэши совпали: это тот же файл, даже если его переименовали или перенесли.
        case match
        /// Хэши не совпали: другой файл.
        case rejected
        /// Сверка невозможна: у потерянного файла хэш не сохранён.
        /// Замену в этом случае не делаем — проверить нечем.
        case cannotVerify
    }

    /// - Parameters:
    ///   - referenceHash: SHA-256 потерянного файла из файла состояния.
    ///   - candidateHash: SHA-256 найденного файла на диске.
    public static func verdict(referenceHash: String?, candidateHash: String?) -> Verdict {
        guard let referenceHash, !referenceHash.isEmpty else {
            return .cannotVerify
        }
        guard let candidateHash, !candidateHash.isEmpty else {
            return .rejected
        }
        return referenceHash.caseInsensitiveCompare(candidateHash) == .orderedSame
            ? .match
            : .rejected
    }

    /// Годится ли вердикт для автоматической подмены пути.
    public static func acceptsReplacement(_ verdict: Verdict) -> Bool {
        verdict == .match
    }
}
