import AVFAudio
import Foundation
import Testing
@testable import Atoroku

/// SegmentWriter のテスト。本物のマイクの代わりに作った音（ラの音）を流し込み、書けたファイルを読み返して確かめる。
/// シミュレーターで動く（マイクは使わない）。
final class SegmentWriterTests {
    let folder: RingBufferFolder

    init() throws {
        folder = RingBufferFolder(
            url: FileManager.default.temporaryDirectory.appending(path: "SegmentWriterTests-\(UUID().uuidString)"))
        try folder.prepare()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder.url)
    }

    @Test func writes16kHzMonoAACAndSwitchesFilesAtTheSegmentLength() throws {
        let writer = SegmentWriter(folder: folder, settings: RecordingSettings(keepDuration: 60, segmentDuration: 2))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))

        feed(writer, format: format, seconds: 5)
        writer.finishSegment()

        // 2秒ごとに切り替わるので、2秒・2秒・1秒の3つ
        let segments = folder.segments()
        try #require(segments.count == 3)
        let durations = try segments.map { try duration(of: $0.url) }
        #expect(abs(durations[0] - 2) < 0.15)
        #expect(abs(durations[1] - 2) < 0.15)
        #expect(abs(durations[2] - 1) < 0.15)
        #expect(abs(writer.recordedSeconds - 5) < 0.1)

        let file = try AVAudioFile(forReading: segments[0].url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test func keepsWritingWhenTheMicrophoneFormatChanges() throws {
        let writer = SegmentWriter(folder: folder, settings: RecordingSettings(keepDuration: 60, segmentDuration: 60))
        // 44.1kHz ステレオで1秒 → 48kHz モノラルで1秒（経路が変わった場面のまね）
        feed(writer, format: try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)), seconds: 1)
        feed(writer, format: try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)), seconds: 1)
        writer.finishSegment()

        let segments = folder.segments()
        try #require(segments.count == 1)
        #expect(abs(try duration(of: segments[0].url) - 2) < 0.15)
    }

    @Test func finishSegmentWithoutAudioDoesNothing() {
        let writer = SegmentWriter(folder: folder, settings: .default)
        writer.finishSegment()
        #expect(folder.segments().isEmpty)
        #expect(writer.recordedSeconds == 0)
    }

    @Test func fileNamesAreUniqueWithinTheSameSecond() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SegmentWriter.uniqueName(in: folder, at: date)
        FileManager.default.createFile(atPath: folder.url.appending(path: first).path(percentEncoded: false), contents: nil)
        let second = SegmentWriter.uniqueName(in: folder, at: date)
        #expect(first == "\(SegmentWriter.timestamp(date)).m4a")
        #expect(second == "\(SegmentWriter.timestamp(date))-2.m4a")
    }

    /// ラの音（440Hz）を、マイクと同じく約0.1秒ずつ渡す。
    private func feed(_ writer: SegmentWriter, format: AVAudioFormat, seconds: Double) {
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var phase = 0.0
        for _ in 0..<Int(seconds * 10) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            buffer.frameLength = chunk
            for frame in 0..<Int(chunk) {
                let sample = Float(sin(phase) * 0.3)
                for channel in 0..<Int(format.channelCount) {
                    buffer.floatChannelData![channel][frame] = sample
                }
                phase += 2 * .pi * 440 / format.sampleRate
            }
            writer.append(buffer)
        }
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
