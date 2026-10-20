import Foundation

/// 録音まわりの設定。
///
/// 段階0では画面から変えられないが、あとで設定画面をつなぐために一か所にまとめておく。
///
/// `nonisolated` は「メインスレッド専用ではない」という印。このプロジェクトは何も書かないと
/// 型がメインスレッド専用（MainActor）になる設定なので、録音用のスレッドからも使う型にはこれを付ける。
/// `Sendable` は「スレッドをまたいで渡しても安全」という印（中身が値だけの struct なので安全）。
nonisolated struct RecordingSettings: Sendable, Equatable {
    /// さかのぼって持っておく長さ（秒）。これより古い音声ファイルは消す。初期値は30分。
    var keepDuration: TimeInterval
    /// 1つの音声ファイルの長さ（秒）。この長さを書いたら次のファイルに切り替える。
    var segmentDuration: TimeInterval

    /// 保存する音声の形式は AAC・16kHz・モノラル。文字起こしには 16kHz で足り、1時間でおよそ15MB。
    static let sampleRate: Double = 16_000
    /// AAC の圧縮の強さ（1秒あたりのビット数）。32kbps で1時間およそ14MB。
    static let bitRate = 32_000

    static let `default` = RecordingSettings(keepDuration: 30 * 60, segmentDuration: 60)

    /// UserDefaults（アプリの小さな設定置き場）に保存した「さかのぼる分数」のキー。
    static let keepMinutesKey = "keepMinutes"

    /// 保存してある設定を読む。まだ何も保存していなければ初期値（30分）。
    static func load(from defaults: UserDefaults = .standard) -> RecordingSettings {
        var settings = RecordingSettings.default
        let minutes = defaults.integer(forKey: keepMinutesKey)  // 保存がなければ 0 が返る
        if minutes > 0 {
            settings.keepDuration = TimeInterval(minutes) * 60
        }
        return settings
    }
}
