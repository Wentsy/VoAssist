import AVFoundation

/// `-joinTest` launch argument (development): the quiet where Chinese and English join, as the audio has it (synthesized
/// whole, no player involved). Each line as VoiceOver before iOS 27 sends it, read a synthesizer per voice (as there),
/// with one synthesizer switching voices inside the SSML (as on iOS 27), and by Tingting alone (her own gaps between
/// words, for comparison); at boost 1 and 4.5. Prints every stretch under -40 dBFS of 8 ms or more inside the speech.
enum JoinTest {
    static func run() {
        Thread {
            let lines = ["打开Safari浏览器", "Wi-Fi 设置", "听见时光beta版", "微信 WeChat 登录", "App Store 有更新", "轻点两下以打开 Safari 浏览器",
                         "设置，Safari", "你好，World", "Hello，世界", "下载完成。App Store", "已连接到 Wi-Fi，信号很好"]
            let main = SystemVoice(), other = SystemVoice(), both = SystemVoice()
            guard let tingting = main.resolve(.tingting) else { print("JT no voice"); return }
            main.warmUp(.tingting); other.warmUp(.samantha); both.warmUp(.samantha, within: .tingting)
            for boost in [1.0, 4.5] {
                var scheme = VoiceScheme.defaultTingting
                scheme.boost = boost
                for text in lines {
                    let ssml = "<speak><lang xml:lang=\"cmn\"><prosody volume=\"-1.9382001dB\">\(ApplePlanner.encode(text))</prosody></lang></speak>"
                    var perVoice: [Float] = []
                    _ = BoostSynthesis.runPerVoice(ssml: ssml, scheme: scheme, settings: BoostSettings(), rules: RuleBook([]),
                                                   main: main, other: other, isCancelled: { false }) { perVoice += $0 }
                    var oneSynth: [Float] = []
                    _ = BoostSynthesis.run(ssml: ssml, scheme: scheme, settings: BoostSettings(), rules: RuleBook([]), voice: both,
                                           isCancelled: { false }) { oneSynth += $0 }
                    var alone: [Float] = []
                    let proc = SegmentProcessor(sampleRate: SystemVoice.sampleRate, stretch: boost, trimLeading: true, trimTrailing: true)
                    _ = main.speak(text, voice: tingting, rate: 0.5, pitch: 1, isCancelled: { false }) { alone += proc.push($0) }
                    alone += proc.finish()
                    print("JT x\(boost) \(text)")
                    print("JT   per voice  \(describe(perVoice))")
                    print("JT   one synth  \(describe(oneSynth))")
                    print("JT   婷婷 alone \(describe(alone))")
                }
            }
            print("JT done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }

    /// Length, and the quiet stretches inside the speech: "at ms: length ms".
    private static func describe(_ pcm: [Float]) -> String {
        let sr = Double(SystemVoice.sampleRate)
        let block = SystemVoice.sampleRate * 4 / 1000
        var quiet: [(Int, Int)] = [] // (start block, blocks)
        var run = 0
        var heard = false
        for b in 0..<(pcm.count / block) {
            let loud = pcm[(b * block)..<((b + 1) * block)].contains { abs($0) > 0.01 }
            if loud {
                if heard && run >= 2 { quiet.append((b - run, run)) }
                heard = true
                run = 0
            } else if heard {
                run += 1
            }
        }
        let gaps = quiet.map { String(format: "%.0f: %.0f", Double($0.0 * block) / sr * 1000, Double($0.1 * block) / sr * 1000) }
        return String(format: "%.0f ms", Double(pcm.count) / sr * 1000) + (gaps.isEmpty ? "" : ", quiet " + gaps.joined(separator: ", "))
    }
}
