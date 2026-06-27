import AppKit
import AVFoundation
import NaturalLanguage

// 系统离线语音朗读 + 逐句高亮。
// 朗读对象由调用方给出:某个 NSTextView 里 bodyRange 这段连续正文(由 MD.speakIdKey 标定)。
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    // synth 仅在主线程使用;标 nonisolated(unsafe) 以免触发 AVSpeechSynthesizer 的非 Sendable 检查
    nonisolated(unsafe) private let synth = AVSpeechSynthesizer()
    private weak var activeTextView: NSTextView?
    private var activeBodyRange = NSRange(location: 0, length: 0)
    private var lastHighlight: NSRange?
    private var activeSpeakId: String?
    private let highlightColor = NSColor.controlAccentColor.withAlphaComponent(0.28)

    override init() {
        super.init()
        synth.delegate = self
    }

    // 当前是否正在朗读这个 id(用于「点同一段=停止」的切换判断)
    func isSpeaking(_ speakId: String) -> Bool {
        return synth.isSpeaking && activeSpeakId == speakId
    }

    // 选嗓音语言:中文→zh-CN,英文→en-US,其它按识别结果,识别不出→系统当前语言
    static func voiceLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else {
            return AVSpeechSynthesisVoice.currentLanguageCode()
        }
        switch lang {
        case .simplifiedChinese, .traditionalChinese: return "zh-CN"
        case .english: return "en-US"
        default: return lang.rawValue
        }
    }

    // 朗读 textView 中 bodyRange 这段;若正在读的就是同一段 → 停止(切换)
    func speak(_ text: String, in textView: NSTextView, bodyRange: NSRange, speakId: String) {
        if isSpeaking(speakId) { stop(); return }
        stop()   // 停掉上一段并清掉旧高亮

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeTextView = textView
        activeBodyRange = bodyRange
        activeSpeakId = speakId

        let utter = AVSpeechUtterance(string: text)
        utter.voice = AVSpeechSynthesisVoice(language: Speaker.voiceLanguage(for: text))
        synth.speak(utter)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        clearHighlight()
        activeSpeakId = nil
        activeTextView = nil
    }

    private func clearHighlight() {
        defer { lastHighlight = nil }
        guard let tv = activeTextView, let storage = tv.textStorage, let r = lastHighlight,
              NSMaxRange(r) <= storage.length else { return }
        storage.removeAttribute(.backgroundColor, range: r)
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let tv = activeTextView, let storage = tv.textStorage else { return }
        clearHighlight()
        let loc = activeBodyRange.location + characterRange.location
        guard characterRange.length > 0, loc >= 0,
              loc + characterRange.length <= storage.length else { return }
        let r = NSRange(location: loc, length: characterRange.length)
        storage.addAttribute(.backgroundColor, value: highlightColor, range: r)
        lastHighlight = r
        tv.scrollRangeToVisible(r)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clearHighlight(); activeSpeakId = nil
    }
}
