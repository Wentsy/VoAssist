#if DEBUG
import AVFoundation

/// Development (the app's `-cpuBench`): the processor time an utterance costs in this process, the voice extension's,
/// read a few ways one after the other, into the diagnostic log as "bench" lines. Nothing else should be speaking
/// through this process meanwhile (the app loads an instance of its own).
enum CPUBench {
    static func run() {
        Thread {
            let short = "打开设置按钮"
            let long = "今天下午三点在会议室开会，请大家准时参加，带上上周的报告和电脑。"
            let sv = SystemVoice()
            let rate = AVSpeechUtteranceMaximumSpeechRate
            for id in ["com.apple.voice.super-compact.zh-CN.Tingting", "com.apple.voice.compact.zh-CN.Tingting"] {
                guard let v = AVSpeechSynthesisVoice(identifier: id) else { DiagnosticLog.write("bench: no \(id)"); continue }
                let name = id.contains("super") ? "super-compact" : "compact"
                _ = sv.speak(short, voice: v, rate: rate, pitch: 1, isCancelled: { false }) { _ in } // loaded
                for text in [short, long] {
                    measure("\(name) text, \(text.count) chars") { got in
                        _ = sv.speak(text, voice: v, rate: rate, pitch: 1, isCancelled: { false }) { got += $0.count }
                    }
                    measure("\(name) SSML, \(text.count) chars") { got in
                        _ = sv.speak(ssml: "<speak>\(text)</speak>", voice: v, stretches: 1, isCancelled: { false }) { pcm, _ in got += pcm.count }
                    }
                }
                if BoostAudioUnit.beforeIOS27 {
                    AnnouncementGuard.bypass = true
                    measure("\(name) text, \(long.count) chars, guard off") { got in
                        _ = sv.speak(long, voice: v, rate: rate, pitch: 1, isCancelled: { false }) { got += $0.count }
                    }
                    AnnouncementGuard.bypass = false
                }
            }
            // the whole of a request, as VoiceOver's are read
            let scheme = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) } ?? VoiceScheme.defaultTingting
            let main = SystemVoice(), other = SystemVoice()
            let ssml = "<speak><prosody rate=\"100%\">\(long)</prosody></speak>"
            for boost in [1.0, scheme.boost] {
                var s = scheme
                s.boost = boost
                measure("request, boost \(boost), \(long.count) chars") { got in
                    var n = 0
                    if BoostAudioUnit.beforeIOS27 {
                        _ = BoostSynthesis.runPerVoice(ssml: ssml, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                       main: main, other: other, isCancelled: { false }) { n += $0.count }
                    } else {
                        _ = BoostSynthesis.runPieces(ssml: ssml, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                     main: main, other: other, isCancelled: { false }) { n += $0.count }
                    }
                    got += n
                }
            }
            // a mixed request: a piece per voice (each its own utterance) against one utterance switching voices
            var one = scheme
            one.boost = 1
            let both = SystemVoice()
            if let sec = one.secondary { both.warmUp(sec, within: one.main) }
            main.warmUp(one.main)
            if let sec = one.secondary { other.warmUp(sec) }
            for text in ["打开 Safari 浏览器，连接 Wi-Fi 网络", long] {
                let mixed = "<speak><prosody rate=\"100%\"><s>\(text)</s><s>按钮</s></prosody></speak>"
                measure("pieces, \(text.count) chars") { got in
                    var n = 0
                    _ = BoostSynthesis.runPieces(ssml: mixed, scheme: one, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                 main: main, other: other, isCancelled: { false }) { n += $0.count }
                    got += n
                }
                measure("one utterance, \(text.count) chars") { got in
                    var n = 0
                    _ = BoostSynthesis.run(ssml: mixed, scheme: one, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                           voice: both, isCancelled: { false }) { n += $0.count }
                    got += n
                }
                if BoostAudioUnit.beforeIOS27 {
                    measure("per voice (iOS 26), \(text.count) chars") { got in
                        var n = 0
                        _ = BoostSynthesis.runPerVoice(ssml: mixed, scheme: one, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                       main: main, other: other, isCancelled: { false }) { n += $0.count }
                        got += n
                    }
                }
            }
            DiagnosticLog.write("bench: done")
        }.start()
    }

    /// Runs `body` 20 times; logs the process's processor time per run and the sound it made.
    private static func measure(_ what: String, _ body: (inout Int) -> Void) {
        let n = 20
        var sound = 0
        let c0 = cpuSeconds(), t0 = Date()
        for _ in 0..<n { body(&sound) }
        let cpu = (cpuSeconds() - c0) * 1000 / Double(n)
        let wall = Date().timeIntervalSince(t0) * 1000 / Double(n)
        DiagnosticLog.write(String(format: "bench %@: %.1f ms CPU, %.1f ms wall per run", what, cpu, wall)
            + (sound > 0 ? String(format: ", %.2f s of sound", Double(sound / n) / Double(SystemVoice.sampleRate)) : ""))
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}
#endif
