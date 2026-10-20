import Foundation
import Observation

/// 計測のための記録（いつ開始・停止・中断・再開したか、バッテリーの残り）。
///
/// 画面に出しつつ、Documents/記録.txt にも1行ずつ足していく。ファイルなのでアプリが落ちても残り、
/// 「ファイル」アプリから読める。音声や会話の中身は書かない。
///
/// @Observable を付けると、SwiftUI の画面が entries の変化を見て自動で描き直す。
@Observable
final class EventLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// 画面に出す分（古い順）。多くなりすぎないよう、最新の maxEntries 件だけ持つ。
    private(set) var entries: [Entry] = []

    @ObservationIgnored private let fileURL: URL
    private static let maxEntries = 200

    /// ファイルの1行は「2026-10-20 09:15:02<タブ>開始（…）」の形
    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")  // 端末の言語設定に左右されない書き方にする
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(fileURL: URL = URL.documentsDirectory.appending(path: "記録.txt")) {
        self.fileURL = fileURL
        loadTail()
    }

    /// 1件足す（画面とファイルの両方）。
    func add(_ text: String, at date: Date = .now) {
        entries.append(Entry(date: date, text: text))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        appendToFile("\(Self.lineFormatter.string(from: date))\t\(text)\n")
    }

    /// 起動したとき、前回までの記録の最後の部分をファイルから読んで画面に出す。
    private func loadTail() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        entries = text.split(separator: "\n").suffix(Self.maxEntries).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let date = Self.lineFormatter.date(from: String(parts[0])) else { return nil }
            return Entry(date: date, text: String(parts[1]))
        }
    }

    private func appendToFile(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // まだファイルがなければ作る
            try? data.write(to: fileURL)
        }
    }
}
