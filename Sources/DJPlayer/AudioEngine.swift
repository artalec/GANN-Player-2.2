import Foundation
import AVFoundation
import Combine
import DJPlayerCore

/// Аудиодвижок с поддержкой trim, seek, громкости, автоперехода на следующий трек.
///
/// Два независимых канала (A и B) для честного кроссфейда. У каждого канала своя
/// цепочка player → EQ → mainMixer. EQ реализует эффект High-cut (плавное
/// закрытие верхов).
final class AudioEngine: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published private(set) var isPlaying = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var currentTime: TimeInterval = 0

    /// Последняя проблема воспроизведения — показывается пользователю.
    /// Раньше ошибки уходили только в NSLog, и трек просто молчал.
    @Published private(set) var lastError: String?

    // MARK: - Настройки и колбеки

    var settings = AppSettings()

    /// Вызывается при завершении трека (дошёл до trimEnd или до конца файла).
    /// AppModel решает: запустить следующий, зациклить, удалить.
    var onTrackFinished: (() -> Void)?

    // MARK: - Внутренние узлы

    private final class Channel {
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        var generation = 0
        /// Формат, с которым канал подключён к движку: переподключаем только при его смене.
        var connectedFormat: AVAudioFormat?

        /// Единственный владелец открытого файла.
        ///
        /// Раньше здесь было два поля — `file` и `streamFile` — и оба указывали на один
        /// и тот же объект. `releaseStream()` обнулял только `streamFile`, поэтому проверка
        /// `file != nil` («канал звучит») продолжала срабатывать для канала, у которого
        /// файл фактически уже не читался. Теперь поле одно, а состояние меняется
        /// только через `load(...)` и `unload()`.
        private(set) var file: AVAudioFile?
        private(set) var converter: AVAudioConverter?
        /// Следующий кадр файла для чтения.
        private(set) var nextFrame: AVAudioFramePosition = 0
        /// Кадр, на котором воспроизведение заканчивается (trimEnd).
        private(set) var endFrame: AVAudioFramePosition = 0

        /// Есть ли в канале загруженный файл. Заменяет прежнюю проверку `file != nil`,
        /// которая расходилась с реальным состоянием потока.
        var isLoaded: Bool { file != nil }

        /// Принимает сегмент во владение.
        func load(_ segment: PreparedSegment, converter: AVAudioConverter?) {
            file = segment.file
            self.converter = converter
            nextFrame = segment.startFrame
            endFrame = segment.endFrame
        }

        /// Сдвигает позицию чтения после прочитанной порции.
        func advance(by frames: AVAudioFramePosition) {
            nextFrame += frames
        }

        /// Переводит чтение на другой участок того же файла: файл остаётся открытым.
        func reseek(to start: AVAudioFramePosition, end: AVAudioFramePosition) {
            nextFrame = start
            endFrame = end
        }

        /// Закрывает файл и освобождает конвертер.
        ///
        /// Единственный путь выгрузки. Раньше `file` и `streamFile` чистились в разных
        /// местах, и одно из них забывали: открытый файл и его дескриптор жили до
        /// следующего запуска трека.
        func unload() {
            file = nil
            converter = nil
            nextFrame = 0
            endFrame = 0
        }
    }

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var activeIndex = 0

    /// Время начала воспроизведения активного сегмента в файле (trimStart + seek).
    private var activeFileOffset: TimeInterval = 0

    private var timeTimer: Timer?
    private var rampTimer: Timer?
    /// Счётчик поколений ramp-анимаций: старый таймер сам себя гасит.
    private var rampGeneration = 0

    /// Идёт плавное затухание (Esc) — завершение трека не должно запускать следующий.
    private var isFadingOut = false

    /// Одна порция звука. Часовой трек читается частями по 3 секунды, поэтому
    /// запуск и перемотка не зависят от длительности файла.
    private let chunkDuration: TimeInterval = 3.0
    /// Сколько порций держим в очереди плеера, чтобы не было разрывов.
    private let chunksAhead = 3

    private let lowPassOpenFrequency: Float = 20000
    private let lowPassClosedFrequency: Float = 180
    /// Частота обновления ramp-анимаций. Значение по времени, а не по шагам:
    /// под нагрузкой или при просадке кадров громкость всё равно меняется за
    /// заданное время, а не «за заданное число тиков».
    private let rampFrameInterval: TimeInterval = 1.0 / 60.0

    // MARK: - Ошибки

    /// Тип ошибки воспроизведения. `Error` нужен потому, что он используется как
    /// `Failure` в `Result<PreparedSegment, PlaybackIssue>`: без соответствия протоколу
    /// `Result` не инстанцируется, и все `.failure(.thisCase)` перестают выводиться.
    enum PlaybackIssue: Error {
        case missingFile(String)
        case unreadable(String)
        case emptySegment(String)
        case engineStartFailed(String)

        var message: String {
            switch self {
            case .missingFile(let path):
                return "Файл не найден: \(path)"
            case .unreadable(let path):
                return "Не удалось открыть файл: \(path)"
            case .emptySegment(let name):
                return "Пустой фрагмент — проверьте точки обрезки: \(name)"
            case .engineStartFailed(let reason):
                return "Не удалось запустить аудиодвижок: \(reason)"
            }
        }
    }

    // MARK: - Инициализация

    init() {
        channels = [Channel(), Channel()]

        for channel in channels {
            engine.attach(channel.player)
            engine.attach(channel.eq)

            let band = channel.eq.bands[0]
            band.filterType = .lowPass
            band.frequency = lowPassOpenFrequency
            band.bypass = true
            channel.eq.bypass = false

            // Единый формат графа: 44.1 кГц стерео. Файлы с другим форматом
            // приводятся к нему конвертером внутри канала. Граф не перестраивается
            // на ходу: connect() на работающем движке с несовпадающим форматом
            // бросает NSException, которую Swift не ловит.
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            engine.connect(channel.player, to: channel.eq, format: format)
            engine.connect(channel.eq, to: engine.mainMixerNode, format: format)
            channel.connectedFormat = format
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — %@", error.localizedDescription)
            report(.engineStartFailed(error.localizedDescription))
        }
        applyVolume()
    }

    // MARK: - Основное управление

    /// Запускает трек. `from` — позиция относительно trimStart, с которой
    /// начинается воспроизведение.
    func play(track: Track, from position: TimeInterval = 0) {
        let start = max(0, min(position, max(0, track.effectiveDuration)))

        // Файл открывается ЗДЕСЬ и только один раз. Проверка отдельным
        // AVAudioFile(forReading:) до остановки текущего трека была двойным
        // открытием на каждый запуск; теперь подготовка и воспроизведение —
        // одна операция.
        let prepared: PreparedSegment
        switch prepareSegment(track: track, position: start) {
        case .success(let segment):
            prepared = segment
        case .failure(let issue):
            report(issue)
            return
        }

        if isPlaying && currentTrack != nil {
            if settings.highCutEnabled {
                transitionWithHighCut(to: track, prepared: prepared)
            } else if settings.crossfadeEnabled {
                transitionWithCrossfade(to: track, prepared: prepared)
            } else {
                hardSwitch(to: track, prepared: prepared)
            }
        } else {
            hardSwitch(to: track, prepared: prepared)
        }
    }

    /// Плавное затухание играющего трека за `duration` секунд и полная
    /// остановка (Esc). Затухают все звучащие каналы: во время crossfade и
    /// high-cut играют два канала, и если погасить только активный, второй
    /// остался бы звучать.
    func fadeOutAndStop(duration: TimeInterval = 1.0) {
        let sounding = channels.filter { $0.isLoaded }

        guard !sounding.isEmpty else {
            stop()
            return
        }

        cancelRamp()
        isFadingOut = true

        let startVolumes = sounding.map { max(0, min($0.player.volume, 1)) }

        scheduleRamp(duration: duration) { progress in
            for (index, channel) in sounding.enumerated() {
                channel.player.volume = startVolumes[index] * (1 - progress)
            }
        } onFinish: { [weak self] in
            // stop() сбросит isFadingOut и вернёт громкость на место
            self?.stop()
        }
    }

    /// Focus Fade: плавно убирает громкость и ставит воспроизведение на паузу.
    /// Позиция сохраняется, поэтому возврат к плееру продолжится с того же места.
    /// Возвращает true, если пауза действительно была выполнена.
    @discardableResult
    func fadeOutPause(duration: TimeInterval = 1.5) -> Bool {
        // Во время перехода играют два канала, и прерывать его нельзя:
        // незавершённый переход оставил бы второй трек звучать.
        guard isPlaying, !isTransitioning, currentTrack != nil else { return false }

        let sounding = channels.filter { $0.isLoaded }
        guard !sounding.isEmpty else { return false }

        cancelRamp()
        isFadingOut = true

        let startVolumes = sounding.map { max(0, min($0.player.volume, 1)) }

        scheduleRamp(duration: duration) { progress in
            for (index, channel) in sounding.enumerated() {
                channel.player.volume = startVolumes[index] * (1 - progress)
            }
        } onFinish: { [weak self] in
            guard let self else { return }
            // Пауза, а не остановка: позиция в файле сохраняется.
            for channel in sounding {
                channel.player.pause()
                // Громкость возвращаем сразу — при возобновлении снова уйдём с нуля.
                channel.player.volume = 1.0
            }
            self.stopTimeTimer()
            self.isPlaying = false
            self.isFadingOut = false
        }

        return true
    }

    /// Focus Fade: плавно возвращает громкость и продолжает воспроизведение
    /// с того места, где оно было поставлено на паузу.
    func fadeInResume(duration: TimeInterval = 1.5) {
        // Возврат может произойти раньше, чем затухание доиграло: тогда трек ещё
        // играет, но громкость уже падает. Такой возврат тоже нужно обработать,
        // иначе музыка дойдёт до нуля и встанет на паузу.
        let interruptingFade = isFadingOut

        guard currentTrack != nil, !isTransitioning else { return }
        guard !isPlaying || interruptingFade else { return }

        let channel = channels[activeIndex]
        guard channel.isLoaded else { return }

        // Снимает незавершённое затухание и сбрасывает isFadingOut.
        cancelRamp()

        let sounding = channels.filter { $0.isLoaded }
        for c in sounding {
            c.player.volume = 0
            c.player.play()
        }
        isPlaying = true
        startTimeTimer()

        scheduleRamp(duration: duration) { progress in
            for c in sounding {
                c.player.volume = progress
            }
        } onFinish: {
            // Вне переходов каналы всегда звучат на 1.0.
            for c in sounding {
                c.player.volume = 1.0
            }
        }
    }

    /// Готовность файла теперь определяется один раз — при чтении длительности
    /// в `WaveformGenerator`. Отдельная проверка открытием файла здесь была вторым
    /// (а с импортом — третьим) открытием того же файла на каждый запуск.

    func stop() {
        cancelRamp()
        for channel in channels {
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
            channel.unload()
        }
        stopTimeTimer()
        isPlaying = false
        isTransitioning = false
        isFadingOut = false
        currentTime = 0
        currentTrack = nil
        activeFileOffset = 0
    }

    func pause() {
        guard isPlaying, !isTransitioning else { return }
        channels[activeIndex].player.pause()
        stopTimeTimer()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, currentTrack != nil, !isTransitioning else { return }
        let channel = channels[activeIndex]
        guard channel.isLoaded else { return }
        channel.player.play()
        isPlaying = true
        startTimeTimer()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if currentTrack != nil {
            resume()
        }
    }

    // MARK: - Seek

    /// Перематывает трек на указанную позицию (0 = начало trimStart).
    /// Работает и во время воспроизведения, и на паузе.
    func seek(to time: TimeInterval) {
        performSeek(to: time, autoplay: isPlaying)
    }

    private func performSeek(to time: TimeInterval, autoplay: Bool) {
        guard let track = currentTrack else { return }

        let position = max(0, min(time, track.effectiveDuration))

        // Готовим сегмент ДО остановки канала: если файл перестал открываться,
        // текущее воспроизведение не оборвётся.
        let prepared: PreparedSegment
        // Перемотка внутри играющего трека: файл уже открыт, второй раз не открываем.
        switch prepareSegment(track: track, position: position, reusing: channels[activeIndex]) {
        case .success(let segment):
            prepared = segment
        case .failure(let issue):
            report(issue)
            return
        }

        channels[activeIndex].player.stop()
        stopTimeTimer()
        isPlaying = false

        // Перезапускаем с новой позиции
        if startSegment(track: track, prepared: prepared, onChannel: activeIndex, autoplay: autoplay) {
            if autoplay {
                isPlaying = true
                startTimeTimer()
            }
        }
    }

    // MARK: - Синхронизация изменённого трека

    /// Обновляет данные играющего трека (цвет, trim-точки, флаги) без перезапуска.
    /// Если изменились trim-точки — пересчитывает позицию, чтобы воспроизведение
    /// продолжалось с того же места в новом сегменте.
    func syncCurrentTrack(_ track: Track) {
        guard let old = currentTrack, old.id == track.id else { return }
        let wasPlaying = isPlaying
        let position = currentTime

        currentTrack = track

        // Путь мог смениться: файл нашли заново автоматическим поиском по хэшу.
        // Тогда открытый файл указывает на старое (уже удалённое) место, и его
        // обязательно надо переоткрыть — переиспользовать нельзя.
        let pathChanged = old.path != track.path
        let boundsChanged = old.trimStart != track.trimStart || old.trimEnd != track.trimEnd

        if pathChanged || boundsChanged {
            let clamped = max(0, min(position, track.effectiveDuration))
            // При смене пути переиспользование запрещено: канал держит файл по
            // прежнему пути. При правке только trim-точек файл тот же — не переоткрываем.
            guard case .success(let prepared) = prepareSegment(track: track,
                                                               position: clamped,
                                                               reusing: pathChanged ? nil : channels[activeIndex]) else {
                return
            }
            // Сохраняем прежнее состояние: если трек стоял на паузе, он должен
            // остаться на паузе после перепланирования.
            if startSegment(track: track, prepared: prepared, onChannel: activeIndex, autoplay: wasPlaying) {
                if wasPlaying {
                    isPlaying = true
                    startTimeTimer()
                }
            }
        }
    }

    // MARK: - Громкость

    func applyVolume() {
        engine.mainMixerNode.outputVolume = Float(max(0, min(settings.volume, 1)))
    }

    // MARK: - Ошибки

    private func report(_ issue: PlaybackIssue) {
        lastError = issue.message
        NSLog("DJPlayer: %@", issue.message)
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Подготовка сегмента

    /// Всё, что нужно для запуска: открытый файл и границы сегмента.
    private struct PreparedSegment {
        let file: AVAudioFile
        let format: AVAudioFormat
        let rate: Double
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
    }

    /// Готовит сегмент трека.
    ///
    /// `reusing` — канал, у которого файл этого же трека уже открыт. Тогда файл
    /// не открывается повторно: перемотка и правка trim-точек внутри трека
    /// обходятся без обращения к диску.
    private func prepareSegment(track: Track,
                                position: TimeInterval,
                                reusing channel: Channel? = nil) -> Result<PreparedSegment, PlaybackIssue> {
        guard track.exists else {
            return .failure(.missingFile(track.path))
        }

        // Решение о переиспользовании — в FileReusePolicy: там же оно покрыто тестами.
        let reused = FileReusePolicy.canReuse(openPath: channel?.file?.url.path,
                                              requestedPath: track.url.path)

        let file: AVAudioFile
        if reused, let open = channel?.file {
            file = open
        } else {
            do {
                file = try AVAudioFile(forReading: track.url)
            } catch {
                return .failure(.unreadable(track.path))
            }
        }

        let format = file.processingFormat
        let rate = format.sampleRate
        let totalFrames = file.length

        guard rate > 0, rate <= 768_000,
              format.channelCount > 0,
              totalFrames > 0 else {
            return .failure(.unreadable(track.path))
        }

        // Позиция в файле = trimStart + position
        let startSec = max(0, track.trimStart + position)
        let startFrame = AVAudioFramePosition(startSec * rate)

        let endSec = track.trimEnd ?? (Double(totalFrames) / rate)
        let endFrame = min(totalFrames, AVAudioFramePosition(endSec * rate))

        guard endFrame > startFrame else {
            return .failure(.emptySegment(track.name))
        }

        return .success(PreparedSegment(file: file,
                                        format: format,
                                        rate: rate,
                                        startFrame: startFrame,
                                        endFrame: endFrame))
    }

    // MARK: - Переключение треков

    private func hardSwitch(to track: Track, prepared: PreparedSegment) {
        cancelRamp()

        for channel in channels {
            // Каналы остановлены — файл больше не звучит. Без этого `file != nil`
            // не означал бы «канал звучит», и плавные эффекты трогали бы тишину.
            channel.generation += 1
            channel.player.stop()
            channel.player.volume = 1.0
            resetLowPass(channel)
            channel.unload()
        }

        activeIndex = 0
        if startSegment(track: track, prepared: prepared, onChannel: 0, autoplay: true) {
            isPlaying = true
        }
    }

    private func transitionWithCrossfade(to track: Track, prepared: PreparedSegment) {
        let oldIndex = activeIndex
        let newIndex = 1 - activeIndex
        cancelRamp()

        guard startSegment(track: track, prepared: prepared, onChannel: newIndex,
                           startVolume: 0, autoplay: true) else { return }

        activeIndex = newIndex
        isTransitioning = true
        isPlaying = true

        let oldChannel = channels[oldIndex]
        let newChannel = channels[newIndex]

        scheduleRamp(duration: settings.crossfadeDuration) { progress in
            oldChannel.player.volume = 1 - progress
            newChannel.player.volume = progress
        } onFinish: { [weak self] in
            oldChannel.generation += 1
            oldChannel.player.stop()
            oldChannel.player.volume = 1.0
            oldChannel.unload()
            self?.isTransitioning = false
        }
    }

    private func transitionWithHighCut(to track: Track, prepared: PreparedSegment) {
        cancelRamp()

        let oldIndex = activeIndex
        let oldChannel = channels[oldIndex]

        isTransitioning = true
        isPlaying = true

        if let band = oldChannel.eq.bands.first {
            band.bypass = false
            band.frequency = lowPassOpenFrequency
        }

        scheduleRamp(duration: settings.highCutDuration) { [weak self] progress in
            guard let self, let band = oldChannel.eq.bands.first else { return }
            let curve = pow(progress, 1.5)
            band.frequency = self.lowPassOpenFrequency * pow(self.lowPassClosedFrequency / self.lowPassOpenFrequency, curve)
            oldChannel.player.volume = max(0, 1 - progress * 0.6)
        } onFinish: { [weak self] in
            guard let self else { return }

            oldChannel.generation += 1
            oldChannel.player.stop()
            oldChannel.player.volume = 1.0
            oldChannel.unload()
            self.resetLowPass(oldChannel)

            // Пауза после high-cut перед запуском следующего
            let pauseAfter = self.settings.highCutPauseAfter
            if pauseAfter > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + pauseAfter) { [weak self] in
                    self?.startAfterHighCut(track: track, prepared: prepared, oldIndex: oldIndex)
                }
            } else {
                self.startAfterHighCut(track: track, prepared: prepared, oldIndex: oldIndex)
            }
        }
    }

    private func startAfterHighCut(track: Track, prepared: PreparedSegment, oldIndex: Int) {
        let newIndex = 1 - oldIndex
        activeIndex = newIndex
        if startSegment(track: track, prepared: prepared, onChannel: newIndex, autoplay: true) {
            isPlaying = true
        }
        isTransitioning = false
    }

    /// Запускает сегмент трека. `prepared` открыт вызывающей стороной ровно один раз.
    @discardableResult
    private func startSegment(track: Track,
                              prepared: PreparedSegment,
                              onChannel index: Int,
                              startVolume: Float = 1.0,
                              autoplay: Bool = true) -> Bool {
        guard index >= 0, index < channels.count else { return false }
        let channel = channels[index]

        // Предыдущий файл этого канала больше не нужен: закрываем до открытия нового.
        // Сравниваем сами объекты, а не флаг «переиспользуем»: если канал уже держит
        // ровно этот файл, закрывать его нельзя — иначе загрузим закрытый.
        if channel.file !== prepared.file {
            channel.unload()
        }

        channel.generation += 1
        let generation = channel.generation

        channel.player.stop()
        channel.player.volume = startVolume
        resetLowPass(channel)

        guard engine.isRunning || startEngineIfNeeded() else { return false }

        let sourceFormat = prepared.format
        let graphFormat = channel.connectedFormat
            ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

        var converter: AVAudioConverter?
        if !Self.formatsMatch(sourceFormat, graphFormat) {
            // Конвертер всегда новый: он хранит состояние ресемплера, и переносить
            // его на другую позицию в файле нельзя — на стыке будет слышен щелчок.
            guard let made = AVAudioConverter(from: sourceFormat, to: graphFormat) else {
                report(.unreadable(track.path))
                return false
            }
            converter = made
        }

        // Файл переходит во владение канала целиком и ровно здесь: дальше он живёт
        // до `unload()` и закрывается в одном месте.
        channel.load(prepared, converter: converter)

        // Очередь плеера заполняется на несколько порций вперёд.
        // Без единой порции трек не запускаем.
        let scheduled = scheduleInitialChunks(on: channel, channelIndex: index,
                                              generation: generation, track: track)
        guard scheduled > 0 else {
            report(.unreadable(track.path))
            channel.unload()
            return false
        }

        // Запуск: плеер, позиция и таймер. Без этого блока трек не стартовал бы.
        if autoplay {
            channel.player.play()
        }

        currentTrack = track
        // Время сегмента: позиция в файле минус trimStart, в пределах сегмента.
        let filePosition = Double(prepared.startFrame) / prepared.rate
        currentTime = max(0, min(track.effectiveDuration, filePosition - track.trimStart))
        activeFileOffset = filePosition
        if autoplay {
            startTimeTimer()
        }

        return true
    }

    /// Ставит в очередь первые порции и возвращает их количество.
    private func scheduleInitialChunks(on channel: Channel, channelIndex: Int,
                                       generation: Int, track: Track) -> Int {
        var queued = 0
        for _ in 0..<chunksAhead {
            if scheduleNextChunk(on: channel, channelIndex: channelIndex,
                                 generation: generation, track: track) {
                queued += 1
            } else {
                break
            }
        }
        return queued
    }

    /// Совпадают ли форматы настолько, что конвертация не нужна.
    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate &&
        a.channelCount == b.channelCount &&
        a.commonFormat == b.commonFormat &&
        a.isInterleaved == b.isInterleaved
    }

    /// Читает и планирует одну порцию звука. По её завершении планируется
    /// следующая, поэтому длительность трека не влияет ни на запуск, ни на память.
    @discardableResult
    private func scheduleNextChunk(on channel: Channel, channelIndex: Int,
                                   generation: Int, track: Track) -> Bool {
        guard channel.generation == generation else { return false }
        guard let source = channel.file, let target = channel.connectedFormat else { return false }

        let remaining = channel.endFrame - channel.nextFrame
        guard remaining > 0 else { return false }

        let sourceFormat = source.processingFormat
        let wanted = AVAudioFrameCount(min(Double(remaining),
                                           max(1, chunkDuration * sourceFormat.sampleRate)))

        source.framePosition = channel.nextFrame
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: wanted) else { return false }
        do {
            try source.read(into: input, frameCount: wanted)
        } catch {
            NSLog("DJPlayer: чтение прервано — %@", error.localizedDescription)
            return false
        }

        let readFrames = input.frameLength
        guard readFrames > 0 else { return false }
        channel.advance(by: AVAudioFramePosition(readFrames))

        guard let buffer = Self.convert(input, using: channel.converter, to: target) else {
            NSLog("DJPlayer: не удалось подготовить порцию звука")
            return false
        }

        let isLastChunk = channel.nextFrame >= channel.endFrame

        channel.player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, channel.generation == generation else { return }

                if isLastChunk {
                    // Поток закончился — файл и конвертер больше не нужны.
                    // Раньше здесь чистился только поток чтения, а сам файл оставался
                    // открытым до следующего запуска трека.
                    channel.unload()

                    guard !self.isFadingOut else { return }
                    if self.activeIndex == channelIndex && !self.isTransitioning {
                        self.stopTimeTimer()
                        self.isPlaying = false
                        self.currentTime = track.effectiveDuration
                        self.onTrackFinished?()
                    }
                } else {
                    // Следующая порция — очередь плеера не пустеет.
                    self.scheduleNextChunk(on: channel, channelIndex: channelIndex,
                                           generation: generation, track: track)
                }
            }
        }
        return true
    }

    /// Приводит порцию к формату графа. Если форматы совпадают, конвертер не нужен.
    private static func convert(_ input: AVAudioPCMBuffer,
                                using converter: AVAudioConverter?,
                                to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return input }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                // Данных больше нет прямо сейчас, но поток продолжится:
                // состояние конвертера сохраняется для следующей порции.
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Запускает движок, если он остановлен. Перестроения графа здесь нет.
    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("DJPlayer: не удалось запустить аудиодвижок — %@", error.localizedDescription)
            report(.engineStartFailed(error.localizedDescription))
            return false
        }
    }

    private func resetLowPass(_ channel: Channel) {
        if let band = channel.eq.bands.first {
            band.frequency = lowPassOpenFrequency
            band.bypass = true
        }
    }

    // MARK: - Ramp-анимации

    /// Запускает плавное изменение по реальному времени.
    ///
    /// Раньше шаги считались тиками таймера: при просадке кадров или занятом
    /// main-run-loop анимация растягивалась, и кроссфейд звучал рвано. Теперь
    /// прогресс считается от systemUptime, а таймер лишь просит перерисовать.
    /// Таймер добавлен в .common, иначе он встаёт во время перетаскивания.
    private func scheduleRamp(duration: TimeInterval,
                              onStep: @escaping (Float) -> Void,
                              onFinish: @escaping () -> Void) {
        cancelRamp()

        let total = max(0.02, duration)
        let start = ProcessInfo.processInfo.systemUptime

        rampGeneration += 1
        let generation = rampGeneration

        let timer = Timer(timeInterval: rampFrameInterval, repeats: true) { [weak self] timer in
            guard let self, generation == self.rampGeneration else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let progress = Float(min(1, max(0, elapsed / total)))
            onStep(progress)

            if progress >= 1 {
                timer.invalidate()
                self.rampTimer = nil
                onFinish()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer

        // Первый шаг сразу: без него на старте слышен щелчок полной громкости.
        onStep(0)
    }

    private func cancelRamp() {
        rampGeneration += 1
        rampTimer?.invalidate()
        rampTimer = nil
        isFadingOut = false
    }

    // MARK: - Отсчёт времени

    private func startTimeTimer() {
        stopTimeTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        timeTimer = timer
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        guard let track = currentTrack else { return }
        let channel = channels[activeIndex]
        guard let nodeTime = channel.player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = channel.player.playerTime(forNodeTime: nodeTime) else {
            return
        }
        // Плеер считает кадры в формате графа, а не файла: для файла с другой
        // частотой деление на частоту файла давало неверную позицию.
        let rate = channel.connectedFormat?.sampleRate
            ?? channel.file?.processingFormat.sampleRate
            ?? 44100
        guard rate > 0 else { return }

        // Текущая позиция в файле
        let fileTime = activeFileOffset + Double(playerTime.sampleTime) / rate

        // Текущее время относительно trimStart
        let relativeTime = fileTime - track.trimStart
        currentTime = max(0, min(track.effectiveDuration, relativeTime))
    }
}
