#if DEBUG
import AVFoundation
import UIKit

/// Development only: how fast VoiceOver itself speaks at its current rate setting. Reads a sentence with the utterance
/// preferring the assistive-technology settings (VoiceOver's rate), and once at the plain default rate; the ratio of the
/// lengths is VoiceOver's speed. Measured both rendered (write, leading/trailing silence trimmed) and spoken aloud
/// (didStart to didFinish), as it is not known which of them honours the setting. For this, VoiceOver's voice must be
/// an Apple voice (Tingting), not one of our schemes.
final class NativeRateProbe: NSObject, AVSpeechSynthesizerDelegate {
    static let text = "今天天气很好，我们一起去公园散步，然后回家吃饭，晚上再看一会儿书。"
    private let synth = AVSpeechSynthesizer()
    private var startedAt: Date?
    private var spoken: ((TimeInterval) -> Void)?
    private var baseline: (seconds: Double, aloud: Double)?
    private(set) var busy = false

    override init() {
        super.init()
        synth.delegate = self
    }

    private func utterance(native: Bool) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: NativeRateProbe.text)
        u.voice = AVSpeechSynthesisVoice(identifier: VoiceEntry.tingting.id) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.prefersAssistiveTechnologySettings = native
        return u
    }

    /// Seconds of speech when rendered, silence before and after trimmed.
    private func render(native: Bool, done: @escaping (Double) -> Void) {
        var pcm: [Float] = []
        var rate = 22050.0
        var over = false
        synth.write(utterance(native: native)) { b in
            guard let p = b as? AVAudioPCMBuffer, !over else { return }
            if p.frameLength == 0 {
                over = true
                let loud = pcm.indices.filter { abs(pcm[$0]) > 0.004 }
                done(loud.isEmpty ? 0 : Double(loud.last! - loud.first!) / rate)
                return
            }
            rate = p.format.sampleRate
            if let f = p.floatChannelData {
                pcm += UnsafeBufferPointer(start: f[0], count: Int(p.frameLength))
            } else if let i = p.int16ChannelData {
                pcm += UnsafeBufferPointer(start: i[0], count: Int(p.frameLength)).map { Float($0) / 32768 }
            }
        }
    }

    /// Seconds from the start to the end of speaking it aloud.
    private func speak(native: Bool, done: @escaping (Double) -> Void) {
        spoken = done
        startedAt = nil
        synth.speak(utterance(native: native))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { startedAt = Date() }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard let t = startedAt, let f = spoken else { return }
        spoken = nil
        f(Date().timeIntervalSince(t))
    }

    /// One measurement at VoiceOver's current rate; `done` gets a line for people and the record. Main thread.
    func measure(done: @escaping (String) -> Void) {
        guard !busy else { return }
        busy = true
        func native(_ base: (seconds: Double, aloud: Double)) {
            render(native: true) { r in
                self.speak(native: true) { a in
                    let line = String(format: "原生 %.2f 倍（播放计时 %.2f 倍）；渲染 %.3f 秒 / 基准 %.3f 秒，播放 %.3f 秒 / 基准 %.3f 秒",
                                      base.seconds / max(r, 0.001), base.aloud / max(a, 0.001), r, base.seconds, a, base.aloud)
                    DebugRecord.append(line, to: "debug_native_rates.json")
                    UIAccessibility.post(notification: .announcement, argument: String(format: "%.2f 倍，播放计时 %.2f 倍", base.seconds / max(r, 0.001), base.aloud / max(a, 0.001)))
                    self.busy = false
                    done(line)
                }
            }
        }
        if let b = baseline {
            native(b)
        } else {
            render(native: false) { r in
                self.speak(native: false) { a in
                    self.baseline = (r, a)
                    native((r, a))
                }
            }
        }
    }
}
#endif
