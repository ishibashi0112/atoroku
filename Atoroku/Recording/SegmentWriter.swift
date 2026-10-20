import AVFAudio
import Foundation

/// マイクから来た音を 16kHz・モノラルの AAC に変えて、1分ごとのファイルに書き分ける係。
///
/// AVAudioEngine のタップ（マイクの音を横から受け取る口）は、メインスレッドではない
/// 音声用のスレッドから呼ばれる。一方で「中断されたのでファイルを閉じる」はメインスレッドから呼ぶ。
/// 両方から同時に触られても壊れないように、中の状態はすべてロック（NSLock）の内側でだけ触る。
/// `@unchecked Sendable` は「スレッドをまたいでも安全なことは、自分で（ロックで）保証している」という宣言。
nonisolated final class SegmentWriter: @unchecked Sendable {
    /// 書き手から録音係（Recorder）への知らせ。
    enum Event: Sendable {
        /// 1つのファイルを書き終えた（ファイル名、録れた秒数、そのとき消した古いファイルの数）
        case segmentFinished(name: String, seconds: Double, pruned: Int)
        /// 書けなかった（ストレージがいっぱい、など）。同じ内容は続けて知らせない。
        case failed(String)
    }

    /// 知らせの流れ。Recorder が `for await` で1つずつ受け取る。
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let folder: RingBufferFolder
    private let settings: RecordingSettings
    /// 書く前の音の形式（16kHz・モノラル・32ビット小数）。AVAudioFile がこれを AAC に圧縮して書く。
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    // ここから下の var は、ロックの内側でだけ触る
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileName: String?
    /// 今のファイルに書いたフレーム数（1フレーム = 1/16000 秒）
    private var framesInFile: AVAudioFramePosition = 0
    /// この待機で書いたフレーム数の合計
    private var totalFrames: AVAudioFramePosition = 0
    private var lastError: String?

    init(folder: RingBufferFolder, settings: RecordingSettings) {
        self.folder = folder
        self.settings = settings
        // 16kHz・1チャンネルの形式は必ず作れるので、ここでの ! は落ちない
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: RecordingSettings.sampleRate, channels: 1, interleaved: false)!
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// マイクの口（inputNode）にタップを付ける。
    ///
    /// ここで作るクロージャ（{ buffer, _ in ... } の部分）は音声用のスレッドで呼ばれる。
    /// メインスレッド専用の場所で作ると「メインスレッド以外から呼ばれた」としてアプリが落ちるので、
    /// メインスレッド専用ではないこの型の中で作っている。
    func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        // bufferSize は「何フレームずつ渡してほしいか」の希望。iOS は約0.1秒ずつ渡してくる。
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }

    /// マイクから届いた音（約0.1秒分）を書く。1分たまったらファイルを閉じて次へ。
    func append(_ buffer: AVAudioPCMBuffer) {
        let event = lock.withLock { appendLocked(buffer) }
        if let event { continuation.yield(event) }
    }

    /// 今書いているファイルを閉じる。中断・停止のときに呼ぶ。
    /// 閉じておけば、このあとアプリが落ちてもそのファイルは再生できる。
    func finishSegment() {
        let event = lock.withLock {
            let event = closeFileLocked()
            converter?.reset()  // 音がいったん途切れるので、変換器の中に残っている音を捨てる
            return event
        }
        if let event { continuation.yield(event) }
    }

    /// この待機で録れた合計の秒数（書きかけのファイルの分も含む）。
    var recordedSeconds: Double {
        lock.withLock { Double(totalFrames) / RecordingSettings.sampleRate }
    }

    /// 新しい待機を始めるときに合計を0に戻す。
    func resetTotals() {
        lock.withLock {
            totalFrames = 0
            lastError = nil
        }
    }

    // MARK: - ここから下はロックの内側から呼ぶ

    private func appendLocked(_ buffer: AVAudioPCMBuffer) -> Event? {
        guard buffer.frameLength > 0 else { return nil }
        do {
            let converted = try convert(buffer)
            guard converted.frameLength > 0 else { return nil }
            if file == nil {
                try openFileLocked()
            }
            try file?.write(from: converted)
            framesInFile += AVAudioFramePosition(converted.frameLength)
            totalFrames += AVAudioFramePosition(converted.frameLength)
            lastError = nil
            // 決めた長さ（1分）を書いたら、ファイルを閉じる。次の音が来たときに新しいファイルを開く。
            if Double(framesInFile) >= settings.segmentDuration * RecordingSettings.sampleRate {
                return closeFileLocked()
            }
            return nil
        } catch {
            // 書けなかったら今のファイルを閉じ、そこまでの音を残す。次の音でまた開き直してみる。
            _ = closeFileLocked()
            let message = ErrorText.describe(error)
            guard message != lastError else { return nil }  // 0.1秒ごとに同じ知らせを出さない
            lastError = message
            return .failed(message)
        }
    }

    /// マイクの形式（iPhone ではたいてい 48kHz）から 16kHz・モノラルに変える。
    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // 入力の形式が変わったら（経路が変わった、など）変換器を作り直す
        if converter?.inputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw WriterError.unsupportedFormat(buffer.format.description)
            }
            newConverter.downmix = true  // ステレオで来ても左右を混ぜて1チャンネルにする
            converter = newConverter
        }
        guard let converter else { throw WriterError.unsupportedFormat(buffer.format.description) }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw WriterError.cannotAllocate
        }

        // 変換器は「次の入力をください」と何度か聞いてくる。
        // 1回目だけ今の音を渡し、2回目からは「今はもうない（.noDataNow）」と答える。
        // 「終わり（.endOfStream）」と答えないのは、変換器の中に残った端数を次の音とつなげるため。
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? WriterError.conversionFailed
        }
        return output
    }

    private func openFileLocked() throws {
        // 「ファイル」アプリから利用者がフォルダごと消していても作り直せるよう、毎回用意する
        try folder.prepare()
        let name = Self.uniqueName(in: folder, at: Date())
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: RecordingSettings.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: RecordingSettings.bitRate,
        ]
        // 拡張子が .m4a なので、入れ物は MPEG-4（ボイスメモと同じ）になる
        file = try AVAudioFile(
            forWriting: folder.url.appending(path: name), settings: fileSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        fileName = name
        framesInFile = 0
    }

    /// ファイルを閉じて仕上げ、古いファイルを消す。開いていなければ何もしない。
    private func closeFileLocked() -> Event? {
        guard let file, let fileName else { return nil }
        // .m4a は閉じるときに目次を書き込む。閉じないまま落ちると、そのファイルは再生できない。
        file.close()
        self.file = nil
        self.fileName = nil
        let seconds = Double(framesInFile) / RecordingSettings.sampleRate
        framesInFile = 0
        let pruned = folder.prune(now: Date(), settings: settings)
        return .segmentFinished(name: fileName, seconds: seconds, pruned: pruned)
    }

    /// ファイル名は書き始めた時刻（例: 20261020-091502.m4a）。同じ秒に2つできたら -2 を付ける。
    static func uniqueName(in folder: RingBufferFolder, at date: Date) -> String {
        let base = timestamp(date)
        var name = "\(base).m4a"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.url.appending(path: name).path(percentEncoded: false)) {
            name = "\(base)-\(number).m4a"
            number += 1
        }
        return name
    }

    /// 日時を「20261020-091502」の形にする（iPhone に設定されたタイムゾーンの時刻）。
    static func timestamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

/// 書き手のエラー。画面と記録に出す文は日本語にしておく。
nonisolated enum WriterError: LocalizedError {
    case unsupportedFormat(String)
    case cannotAllocate
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "この音の形式は変換できない: \(format)"
        case .cannotAllocate: "音を入れる場所を用意できなかった"
        case .conversionFailed: "16kHz への変換に失敗した"
        }
    }
}
