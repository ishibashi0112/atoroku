import AVFAudio
import Foundation

/// エラーを記録に残せる短い文にする。
///
/// iOS の音声のエラーは「OSStatus error 561145187」のように数字だけのことが多い。
/// この数字は4文字の英字を詰めたもの（561145187 なら '!rec'）なので、それも添え、
/// よく出るものには日本語の意味を付ける。段階0の計測で「なぜ再開できなかったか」を読むため。
nonisolated enum ErrorText {
    static func describe(_ error: Error) -> String {
        // 自分で作ったエラー（日本語の説明つき）はそのまま
        if let local = error as? LocalizedError, let description = local.errorDescription {
            return description
        }
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code)"
        if let code = fourCharacterCode(nsError.code) {
            text += " '\(code)'"
        }
        if let meaning = meaning(of: nsError.code) {
            text += "（\(meaning)）"
        }
        return text
    }

    /// 数字を4文字の英字に戻す。英字にならない数字なら nil。
    static func fourCharacterCode(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let value = UInt32(code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 音声セッションのよくあるエラーの意味。
    static func meaning(of code: Int) -> String? {
        switch AVAudioSession.ErrorCode(rawValue: code) {
        case .cannotStartRecording: "裏に回っているので録音を始められない"
        case .cannotInterruptOthers: "他のアプリが音を使っていて割り込めない"
        case .insufficientPriority: "通話中などで優先度が足りない"
        case .isBusy: "音声の仕組みが使用中"
        case .mediaServicesFailed: "iOS の音声の仕組みが止まった"
        case .siriIsRecording: "Siri が録音中"
        default: nil
        }
    }
}
