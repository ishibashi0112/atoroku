import Foundation
import Testing
@testable import Atoroku

/// 古いファイルを消す決まりのテスト。
struct RingBufferPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = RecordingSettings(keepDuration: 30 * 60, segmentDuration: 60)

    private func segment(minutesAgo: Double) -> Segment {
        Segment(url: URL(filePath: "/tmp/\(minutesAgo).m4a"), startedAt: now.addingTimeInterval(-minutesAgo * 60), bytes: 0)
    }

    @Test func removesOnlyFilesThatEndedBeforeTheWindow() {
        // 30分 + 1ファイル分（1分）= 31分より前に書き始めたものだけが古い
        let segments = [40, 31.5, 30.5, 1].map { segment(minutesAgo: $0) }
        let expired = RingBufferPolicy.expired(segments, now: now, settings: settings)
        #expect(expired == [segments[0], segments[1]])
    }

    @Test func keepsEverythingWhenAllFilesAreRecent() {
        let segments = [29, 10, 0].map { segment(minutesAgo: $0) }
        #expect(RingBufferPolicy.expired(segments, now: now, settings: settings).isEmpty)
    }
}

/// フォルダ（本物のファイル）のテスト。
final class RingBufferFolderTests {
    let folder: RingBufferFolder

    init() throws {
        folder = RingBufferFolder(
            url: FileManager.default.temporaryDirectory.appending(path: "RingBufferFolderTests-\(UUID().uuidString)"))
        try folder.prepare()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder.url)
    }

    @Test func isExcludedFromBackup() throws {
        let values = try folder.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func pruneDeletesOldFilesAndListsTheRestOldestFirst() throws {
        let now = Date.now
        for (name, minutesAgo) in [("a", 45.0), ("b", 2.0), ("c", 32.0), ("d", 10.0)] {
            let path = folder.url.appending(path: "\(name).m4a").path(percentEncoded: false)
            FileManager.default.createFile(atPath: path, contents: Data(count: 100))
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: path)
        }
        // 音声ファイル以外は数えない・消さない
        let memo = folder.url.appending(path: "memo.txt").path(percentEncoded: false)
        FileManager.default.createFile(atPath: memo, contents: nil)

        let removed = folder.prune(now: now, settings: RecordingSettings(keepDuration: 30 * 60, segmentDuration: 60))

        #expect(removed == 2)
        #expect(folder.segments().map(\.url.lastPathComponent) == ["d.m4a", "b.m4a"])
        #expect(folder.segments().allSatisfy { $0.bytes == 100 })
        #expect(FileManager.default.fileExists(atPath: memo))
    }
}

/// エラーの書き方のテスト。
struct ErrorTextTests {
    @Test func decodesFourCharacterCodes() {
        #expect(ErrorText.fourCharacterCode(561_145_187) == "!rec")
        #expect(ErrorText.fourCharacterCode(-50) == nil)
    }

    @Test func explainsAudioSessionErrors() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187)
        #expect(ErrorText.describe(error) == "NSOSStatusErrorDomain 561145187 '!rec'（裏に回っているので録音を始められない）")
    }
}
