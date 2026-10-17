import Foundation
import CryptoKit
import DJPlayerCore

/// Ищет на диске файл, пропавший из плейлиста, и проверяет, что найденное — именно он.
///
/// Поиск идёт в фоне и никогда не трогает интерфейс: всё, что возвращается наружу,
/// уже готово к применению на главном потоке.
///
/// Три вещи, от которых зависит поведение:
///  1. кандидатов даёт Spotlight-индекс (`mdfind`), а не обход диска: полный обход
///     домашнего каталога занимает минуты и грузит диск;
///  2. отсев по имени и размеру идёт до хэширования — считать SHA-256 у всех
///     одноимённых файлов было бы неоправданно дорого;
///  3. хэш считается потоково, порциями по мегабайту: файл на несколько гигабайт
///     не должен целиком попадать в память.
enum FileRelinker {

    /// Сколько кандидатов просматривать максимум. Одноимённых файлов обычно единицы;
    /// ограничение защищает от случаев вроде `track.mp3` в сотне папок.
    private static let maximumCandidates = 24

    /// Предел ожидания `mdfind`. Если индекс не отвечает, поиск прекращается,
    /// а не висит фоном.
    private static let searchTimeout: TimeInterval = 20

    private static let queue = DispatchQueue(label: "FileRelinker.queue", qos: .utility)

    /// Результат поиска.
    struct Outcome {
        /// Путь к найденному файлу, если он опознан по хэшу.
        var path: String?
    }

    // MARK: - Поиск

    /// Ищет замену потерянному файлу.
    ///
    /// - Parameters:
    ///   - referenceHash: SHA-256 пропавшего файла. Обязателен: без него сверять нечем.
    ///   - referenceSize: размер пропавшего файла, если известен. Только для отсева.
    ///   - originalPath: где файл лежал. Используется, чтобы искать рядом.
    ///   - takenPaths: пути, уже занятые другими треками. Подставлять их нельзя:
    ///     два трека с одним файлом сломают и нумерацию, и обрезку.
    static func findReplacement(referenceHash: String?,
                                referenceSize: Int64?,
                                originalPath: String,
                                excluding takenPaths: Set<String>) async -> Outcome {
        // Сверять нечем — не ищем. Иначе пришлось бы подменять по имени, а это
        // подставило бы чужие настройки обрезки к другому аудио.
        guard let referenceHash, !referenceHash.isEmpty else {
            return Outcome()
        }
        let fileName = (originalPath as NSString).lastPathComponent
        // Файл не пропал (мог появиться обратно, пока шёл поиск) — искать нечего.
        if FileManager.default.fileExists(atPath: originalPath) {
            return Outcome(path: originalPath)
        }

        guard !fileName.isEmpty else { return Outcome() }

        let candidates = await searchCandidates(named: fileName)
        guard !candidates.isEmpty else { return Outcome() }

        return await withCheckedContinuation { continuation in
            queue.async {
                // Сначала те, что лежат рядом с исходным местом: файл чаще всего
                // перемещают в соседнюю папку или на другой диск, сохраняя структуру.
                let originalDirectory = (originalPath as NSString).deletingLastPathComponent
                let ordered = candidates.sorted { lhs, rhs in
                    let lhsNear = lhs.hasPrefix(originalDirectory)
                    let rhsNear = rhs.hasPrefix(originalDirectory)
                    if lhsNear != rhsNear { return lhsNear }
                    return lhs < rhs
                }

                for path in ordered.prefix(maximumCandidates) {
                    if takenPaths.contains(path) { continue }

                    // Размер проверяем до хэша: чтение гигабайта ради заведомо
                    // неподходящего файла — пустая работа.
                    if let referenceSize,
                       let size = byteSize(at: path),
                       size != referenceSize {
                        continue
                    }

                    let candidateHash = contentHash(of: URL(fileURLWithPath: path))
                    let verdict = RelinkPolicy.verdict(referenceHash: referenceHash,
                                                       candidateHash: candidateHash)
                    guard RelinkPolicy.acceptsReplacement(verdict) else {
                        // Хэш не совпал: другой файл с тем же именем.
                        // Дальше по списку — там может быть настоящий.
                        continue
                    }

                    continuation.resume(returning: Outcome(path: path))
                    return
                }

                continuation.resume(returning: Outcome())
            }
        }
    }

    // MARK: - Кандидаты из индекса

    /// Запрашивает у Spotlight все файлы с указанным именем.
    private static func searchCandidates(named fileName: String) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                // Точное совпадение имени: `-name` ищет по подстроке в путях,
                // а нам нужны только одноимённые файлы.
                process.arguments = ["-name", fileName]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    NSLog("DJPlayer: mdfind не запустился — %@", error.localizedDescription)
                    continuation.resume(returning: [])
                    return
                }

                // Ожидание с пределом: зависший индекс не должен держать поиск вечно.
                let deadline = Date().addingTimeInterval(searchTimeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    NSLog("DJPlayer: mdfind не ответил за %@ с — поиск прекращён",
                          String(searchTimeout))
                    process.terminate()
                    continuation.resume(returning: [])
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)

                // Вывод построчный. Берём только обычные файлы с точно таким именем:
                // mdfind может вернуть и папки, и файлы с похожими именами.
                let paths = text
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { ($0 as NSString).lastPathComponent == fileName }

                continuation.resume(returning: paths)
            }
        }
    }

    // MARK: - Содержимое файла

    /// Размер файла на диске. nil — файл не читается.
    static func byteSize(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
    }

    /// SHA-256 содержимого файла, потоково.
    ///
    /// nil — файл не открылся или в нём нет данных: пустой файл не может быть
    /// заменой непустому.
    static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0

        // Порция в 1 МБ: достаточно крупная, чтобы не тратить время на системные
        // вызовы, и достаточно мелкая, чтобы многочасовой файл не попал в память целиком.
        let chunkSize = 1 << 20

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                NSLog("DJPlayer: не удалось прочитать %@ — %@",
                      url.lastPathComponent, error.localizedDescription)
                return nil
            }

            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }

        guard total > 0 else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
