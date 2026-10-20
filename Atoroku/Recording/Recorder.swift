import AVFAudio
import Foundation
import Observation
import UIKit

/// 録音の芯。
///
/// - 音声セッション（AVAudioSession）: iPhone に「録音しながら、他のアプリの音も止めずに使う」と申告する。
/// - AVAudioEngine: マイクの音を受け取る仕組み。受け取った音は SegmentWriter が1分ごとのファイルに書く。
/// - 中断（通話など）や音の経路の変化（イヤホンの抜き差しなど）で止まったら、自動で再開を試みる。
///
/// 画面（SwiftUI）から直接見られるように @Observable にしてある。このクラスはメインスレッドで動く。
@Observable
final class Recorder {
    enum Status: Equatable {
        /// 止まっている
        case stopped
        /// 開始の途中（マイクの許可を待っている、など）
        case starting
        /// 録音中（待機中）
        case recording
        /// 中断中（通話などが終わるのを待っている）
        case interrupted
        /// 始められなかった（理由つき）
        case failed(String)
    }

    private(set) var status: Status = .stopped
    /// 「開始」を押した時刻。止まっているときは nil。
    private(set) var startedAt: Date?
    /// この待機で中断された回数
    private(set) var interruptionCount = 0
    /// 今使っているマイクの名前（例: 「iPhone マイク」）
    private(set) var inputName: String?

    let log: EventLog
    let settings: RecordingSettings
    let folder: RingBufferFolder

    /// 「停止」ボタンを出すかどうか（録音中・中断中・開始の途中）
    var isRunning: Bool {
        switch status {
        case .starting, .recording, .interrupted: true
        case .stopped, .failed: false
        }
    }

    // @ObservationIgnored は「画面の描き直しには関係ない」印
    @ObservationIgnored private let writer: SegmentWriter
    @ObservationIgnored private var engine: AVAudioEngine?
    /// 「開始」から「停止」まで true。中断が終わったときに再開するかどうかはこれで決める。
    @ObservationIgnored private var wantsToRecord = false
    /// 再開に失敗したときの「少し待ってもう一度」
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastBatteryLogAt: Date?
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// 自動の再開を試す回数（2, 4, 8, 16, 32 秒あけて、合わせて約1分）
    private static let maxResumeAttempts = 6

    /// UserDefaults に置く値の名前
    private enum Keys {
        /// 録音中なら true。停止ボタンで false に戻す。次の起動で true のままなら、停止ボタンなしで終わったということ。
        static let wasRecording = "recording.wasRecording"
        /// 最後に録音が動いていた時刻（1分ごとに更新）
        static let lastAliveAt = "recording.lastAliveAt"
    }

    init(settings: RecordingSettings = .load(), folder: RingBufferFolder = .standard, log: EventLog = EventLog()) {
        self.settings = settings
        self.folder = folder
        self.log = log
        writer = SegmentWriter(folder: folder, settings: settings)
        UIDevice.current.isBatteryMonitoringEnabled = true  // これをしないとバッテリーの残りが読めない
        observeNotifications()
        listenToWriter()
        checkPreviousRun()
    }

    // MARK: - 開始と停止

    /// 「開始」ボタン。アプリが前面にあるときに呼ぶ（iOS は裏からは録音を始めさせてくれない）。
    func start() async {
        switch status {
        case .stopped, .failed: break
        case .starting, .recording, .interrupted: return  // すでに動いている
        }
        status = .starting

        // 1. マイクを使ってよいか聞く（初回だけ許可の画面が出る）
        let granted = await AVAudioApplication.requestRecordPermission()
        guard status == .starting else { return }  // 許可の画面の間に「停止」が押された
        guard granted else {
            status = .failed("マイクが許可されていません。設定アプリ > あとろく > マイク をオンにしてください。")
            log.add("開始できなかった: マイクが許可されていない")
            return
        }

        // 2. この待機の数字を0から数え直す
        wantsToRecord = true
        startedAt = .now
        interruptionCount = 0
        writer.resetTotals()
        lastBatteryLogAt = .now
        defaults.set(true, forKey: Keys.wasRecording)
        defaults.set(Date.now, forKey: Keys.lastAliveAt)

        // 3. 音声セッションとエンジンを動かす
        do {
            try folder.prepare()
            folder.prune(now: .now, settings: settings)  // 前回の待機の古いファイルを片付ける
            try activateSession()
            try startEngine()
            status = .recording
            log.add("開始（さかのぼる長さ \(keepMinutes)分、バッテリー \(Self.batteryText)、マイク \(inputName ?? "不明")）")
        } catch {
            let message = ErrorText.describe(error)
            wantsToRecord = false
            stopEngine()
            deactivateSession()
            startedAt = nil
            defaults.set(false, forKey: Keys.wasRecording)
            status = .failed("開始できませんでした: \(message)")
            log.add("開始できなかった: \(message)")
        }
    }

    /// 「停止」ボタン。今のファイルを閉じて、マイクを手放す。録れたファイルは消さない
    /// （段階0で聞き比べるため。古いものは次の待機のときに消える）。
    func stop() {
        let wasRunning = wantsToRecord
        wantsToRecord = false
        retryTask?.cancel()
        retryTask = nil
        stopEngine()
        deactivateSession()
        if wasRunning, let startedAt {
            log.add(
                "停止（経過 \(Format.duration(Date.now.timeIntervalSince(startedAt)))、"
                    + "録れた時間 \(Format.duration(writer.recordedSeconds))、中断 \(interruptionCount)回、"
                    + "バッテリー \(Self.batteryText)）")
        }
        startedAt = nil
        status = .stopped
        defaults.set(false, forKey: Keys.wasRecording)
    }

    /// アプリが前面に来たとき（画面から呼ぶ）。中断から戻れていなければもう一度試す。
    /// 前面にいれば録音を始め直せるので、裏で再開に失敗していてもここで戻れることが多い。
    func appBecameActive() {
        if wantsToRecord, status == .interrupted {
            resume(reason: "アプリを開いた")
        }
    }

    // MARK: - 画面に出す数字

    struct Snapshot {
        /// 開始からの経過時間（止まっていれば nil）
        var elapsed: TimeInterval?
        /// 実際に録れた時間。経過時間より短ければ、その分どこかで止まっていた。
        var recordedSeconds: Double
        var fileCount: Int
        var totalBytes: Int64
        var freeBytes: Int64?
    }

    func snapshot(at now: Date = .now) -> Snapshot {
        let segments = folder.segments()
        return Snapshot(
            elapsed: startedAt.map { now.timeIntervalSince($0) },
            recordedSeconds: writer.recordedSeconds,
            fileCount: segments.count,
            totalBytes: segments.reduce(0) { $0 + $1.bytes },
            freeBytes: RingBufferFolder.freeSpace())
    }

    var keepMinutes: Int { Int(settings.keepDuration / 60) }

    /// バッテリーの残り（例: 「82%」）。シミュレーターなどで読めなければ「不明」。
    static var batteryText: String {
        let level = UIDevice.current.batteryLevel  // 0.0〜1.0。読めないときは -1
        return level < 0 ? "不明" : "\(Int((level * 100).rounded()))%"
    }

    // MARK: - 音声セッションとエンジン

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord: 録音しながら音も鳴らせる使い方
        // mixWithOthers: 音楽や動画を止めずに一緒に使う（他のアプリの邪魔をしない）
        // allowBluetoothA2DP: Bluetooth イヤホンは高音質の再生専用（A2DP）にする。
        //   イヤホンのマイクを使う設定（allowBluetoothHFP）は付けない。付けると通話用の低音質に切り替わり、音楽がこもる。
        // defaultToSpeaker: 何もつないでいないとき、他のアプリの音が受話口（耳に当てる所）から小さく鳴らないよう、
        //   本体のスピーカーから鳴らす
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        // 着信の呼び出し音だけでは録音を止めない（電話に出たときだけ止まる）
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
        preferBuiltInMic()
    }

    private func deactivateSession() {
        // notifyOthersOnDeactivation: マイクを手放したことを他のアプリに知らせる
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// マイクを iPhone 本体に固定する（有線イヤホンなどをつないでも、そちらのマイクに切り替わらないように）。
    private func preferBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
           session.preferredInput?.uid != builtIn.uid {
            do {
                try session.setPreferredInput(builtIn)
            } catch {
                log.add("本体のマイクを選べなかった: \(ErrorText.describe(error))")
            }
        }
        inputName = session.currentRoute.inputs.first?.portName
    }

    /// エンジンを作って動かす。再開のたびに作り直す（古いエンジンを直して使うより確実なため）。
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 通話中などでマイクが使えないと、形式が「0Hz・0チャンネル」になる。そのままタップを付けるとアプリが落ちる。
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.microphoneUnavailable
        }
        writer.installTap(on: input, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// エンジンを止めて、書きかけのファイルを閉じる。
    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        writer.finishSegment()
    }

    /// 再開を試みる。失敗したら少しずつ間をあけて、何回か試し直す。
    private func resume(reason: String, attempt: Int = 1) {
        retryTask?.cancel()
        retryTask = nil
        guard wantsToRecord else { return }
        do {
            stopEngine()  // 念のため古いエンジンを片付けてから
            try activateSession()
            try startEngine()
            status = .recording
            log.add("再開した（\(reason)\(attempt > 1 ? "、\(attempt)回目" : "")）")
        } catch {
            status = .interrupted
            log.add("再開できなかった（\(reason)、\(attempt)回目）: \(ErrorText.describe(error))")
            guard attempt < Self.maxResumeAttempts else {
                log.add("自動の再開をやめた。アプリを開くと、もう一度試す")
                return
            }
            let delay = pow(2, Double(attempt))  // 2秒、4秒、8秒…
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.resume(reason: reason, attempt: attempt + 1)
            }
        }
    }

    // MARK: - iOS からの知らせ

    /// 中断・経路の変化などの知らせを受け取るように登録する。
    /// 知らせは別のスレッドから来ることがあるので、queue: .main でメインスレッドに回してもらい、
    /// MainActor.assumeIsolated で「ここはメインスレッド」と Swift に伝えてから処理する。
    /// （Recorder はアプリが終わるまで使い続けるので、登録の解除はしない）
    private func observeNotifications() {
        let center = NotificationCenter.default

        // 中断（電話に出た、他のアプリが録音を始めた、Siri など）。
        // iOS 27 では別の知らせに置き換わるが、iPhone が iOS 26 なのでこれを使う。
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                [weak self] note in
                let info = note.userInfo ?? [:]
                let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt
                MainActor.assumeIsolated {
                    self?.handleInterruption(type: type, options: options, reason: reason)
                }
            })

        // 音の経路の変化（イヤホンの抜き差し、Bluetooth の接続など）
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated {
                    self?.handleRouteChange(reason: reason)
                }
            })

        // iOS の音声の仕組みそのものが再起動した（まれ）
        observers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleMediaServicesReset()
                }
            })

        // マイクの形式が変わってエンジンが自分で止まった
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
                [weak self] note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    self?.handleEngineConfigurationChange(sender: sender)
                }
            })

        // アプリが終了させられる直前（アプリの切り替え画面で上にはじいた、など）
        observers.append(
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillTerminate()
                }
            })
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions, reason: UInt?
    ) {
        guard wantsToRecord, let type else { return }
        switch type {
        case .began:
            // iOS がすでにエンジンを止めている。今のファイルを閉じて、そこまでの音を確実に残す。
            retryTask?.cancel()
            retryTask = nil
            stopEngine()
            interruptionCount += 1
            status = .interrupted
            log.add("中断された（\(Self.interruptionReasonText(reason))）")
        case .ended:
            log.add("中断が終わった（iOS からの再開の合図: \(options.contains(.shouldResume) ? "あり" : "なし")）")
            // 合図が「なし」でも再開を試みる。録り続けるのがこのアプリの役目なので。
            resume(reason: "中断のあと")
        @unknown default:
            break
        }
    }

    private static func interruptionReasonText(_ reason: UInt?) -> String {
        switch reason.flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) {
        case .builtInMicMuted: "本体のマイクがミュートされた"
        case .routeDisconnected: "音の経路が切れた"
        case .default, nil: "通話・他のアプリの録音・Siri など"
        default: "理由の番号 \(reason ?? 0)"
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        guard wantsToRecord else { return }
        preferBuiltInMic()
        switch reason {
        case .newDeviceAvailable: log.add("機器がつながった（マイク: \(inputName ?? "不明")）")
        case .oldDeviceUnavailable: log.add("機器が外れた（マイク: \(inputName ?? "不明")）")
        default: break
        }
        // 経路が変わってエンジンが止まっていたら、つなぎ直す
        if status == .recording, engine?.isRunning != true {
            resume(reason: "音の経路が変わったあと")
        }
    }

    private func handleEngineConfigurationChange(sender: ObjectIdentifier?) {
        // 今のエンジンからの知らせだけを扱う（作り直す前の古いエンジンの知らせは無視する）
        guard wantsToRecord, status == .recording, let engine, sender == ObjectIdentifier(engine) else { return }
        log.add("マイクの形式が変わったので、録音をつなぎ直す")
        resume(reason: "形式が変わったあと")
    }

    private func handleMediaServicesReset() {
        guard wantsToRecord else { return }
        log.add("iOS の音声の仕組みがリセットされた。作り直す")
        engine = nil  // 古いエンジンはもう使えないので、触らずに捨てる
        writer.finishSegment()
        resume(reason: "リセットのあと")
    }

    private func handleWillTerminate() {
        guard wantsToRecord else { return }
        writer.finishSegment()  // 書きかけのファイルを閉じて、再生できる形で残す
        log.add("アプリが終了させられる（録音中だった）")
        // wasRecording は true のまま残す。次の起動で「停止ボタンなしで終わった」と記録するため。
    }

    // MARK: - 書き手からの知らせと、前回の確認

    private func listenToWriter() {
        let events = writer.events
        // この Task はメインスレッドで動く（Recorder の中で作ったため）
        Task { [weak self] in
            for await event in events {
                self?.handleWriterEvent(event)
            }
        }
    }

    private func handleWriterEvent(_ event: SegmentWriter.Event) {
        switch event {
        case .segmentFinished:
            // 1分ごとの「動いている」印。停止ボタンなしで終わったとき、次の起動で最後に動いていた時刻がわかる。
            defaults.set(Date.now, forKey: Keys.lastAliveAt)
            logBatteryEveryHour()
        case .failed(let message):
            log.add("書き込めなかった: \(message)")
        }
    }

    /// 1時間ごとにバッテリーの残りを記録する（段階0の計測用）。
    private func logBatteryEveryHour() {
        guard wantsToRecord else { return }
        let now = Date.now
        if let last = lastBatteryLogAt, now.timeIntervalSince(last) < 60 * 60 { return }
        lastBatteryLogAt = now
        let elapsed = startedAt.map { Format.duration(now.timeIntervalSince($0)) } ?? "不明"
        log.add(
            "経過 \(elapsed): バッテリー \(Self.batteryText)、録れた時間 \(Format.duration(writer.recordedSeconds))、"
                + "中断 \(interruptionCount)回")
    }

    /// 起動したとき、前回の待機が停止ボタンなしで終わっていたら（強制終了・クラッシュなど）記録に残す。
    private func checkPreviousRun() {
        guard defaults.bool(forKey: Keys.wasRecording) else { return }
        defaults.set(false, forKey: Keys.wasRecording)
        let lastAlive = (defaults.object(forKey: Keys.lastAliveAt) as? Date).map(Format.dateTime) ?? "不明"
        log.add("前回の待機は停止ボタンなしで終わっていた（アプリが終了させられたか、落ちた）。最後に録音が動いていたのは \(lastAlive)")
    }
}

nonisolated enum RecorderError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "マイクが使えない（通話中など）"
        }
    }
}

/// 画面と記録で使う、時間や大きさの書き方。
enum Format {
    /// 秒数を「1:23:45」の形にする
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }

    /// バイト数を「14.2 MB」の形にする
    static func bytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// 日時を「10/20 9:15:02」の形にする
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().hour().minute().second())
    }
}
