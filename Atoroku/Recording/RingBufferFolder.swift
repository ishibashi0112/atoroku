import Foundation

/// 音声ファイル1つ分の情報。
nonisolated struct Segment: Sendable, Equatable {
    let url: URL
    /// 書き始めた時刻（ファイルの作成日時）
    let startedAt: Date
    /// ファイルの大きさ（バイト）
    let bytes: Int64
}

/// 1分ごとの音声ファイルを置くフォルダ（リングバッファ）。
///
/// リングバッファは「決まった量だけ持ち、古いものから捨てていく入れ物」のこと。
/// メモリではなくストレージにファイルとして置くので、アプリが落ちても直前までの音が残り、
/// 長さを30分にしても半日にしてもメモリの使い方は変わらない。
nonisolated struct RingBufferFolder: Sendable {
    let url: URL

    /// 本番で使う場所: Documents/RingBuffer。Documents は「ファイル」アプリから見える（Info.plist の設定）。
    static var standard: RingBufferFolder {
        RingBufferFolder(url: URL.documentsDirectory.appending(path: "RingBuffer", directoryHint: .isDirectory))
    }

    /// フォルダを作り、iCloud やパソコンへのバックアップから外す。
    ///
    /// 「音声は iPhone の外に出さない」ため。iCloud バックアップがオンだと、
    /// 何もしなければ Documents の中身はクラウドに上がってしまう。
    /// 何度呼んでもよい（すでにあれば何もしない）。
    func prepare() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folderURL = url  // setResourceValues は var の URL にしか呼べないので写す
        try folderURL.setResourceValues(values)
    }

    /// フォルダの中の音声ファイルを、古い順に並べて返す。
    func segments() -> [Segment] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "m4a" }
            .compactMap { fileURL -> Segment? in
                guard let values = try? fileURL.resourceValues(forKeys: keys),
                      let created = values.creationDate else { return nil }
                return Segment(url: fileURL, startedAt: created, bytes: Int64(values.fileSize ?? 0))
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// 古くなったファイルを消す。消した数を返す。
    /// 「ファイル」アプリから利用者が先に消していてもかまわない（消せなかった分は数えないだけ）。
    @discardableResult
    func prune(now: Date, settings: RecordingSettings) -> Int {
        var removed = 0
        for segment in RingBufferPolicy.expired(segments(), now: now, settings: settings) {
            if (try? FileManager.default.removeItem(at: segment.url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// iPhone の残り容量（バイト）。わからなければ nil。
    static func freeSpace() -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// どのファイルを消すかの決まり。ファイルに触らない計算だけなので、テストしやすいよう分けてある。
nonisolated enum RingBufferPolicy {
    /// 「今から keepDuration 前」より前に終わったファイルを古いとみなす。
    ///
    /// 1つのファイルは書き始めから segmentDuration 以内に終わるので、
    /// 書き始めが「今 −（keepDuration + segmentDuration）」より前なら確実に古い。
    /// こうすると、押す前の30分を必ず含む分（最大で 30分 + 1ファイル分）が残る。
    static func expired(_ segments: [Segment], now: Date, settings: RecordingSettings) -> [Segment] {
        let limit = now.addingTimeInterval(-(settings.keepDuration + settings.segmentDuration))
        return segments.filter { $0.startedAt < limit }
    }
}
