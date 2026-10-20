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

    /// `rateBench`: the same request at the same final speed, the voice reading it at VoiceOver's normal rate and boosted
    /// by Sonic, or reading it faster itself and boosted less: what the voice's speed saves.
    static func rates() {
        Thread {
            let long = "今天下午三点在会议室开会，请大家准时参加，带上上周的报告和电脑。"
            let base = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) } ?? VoiceScheme.defaultTingting
            let main = SystemVoice(), other = SystemVoice()
            main.warmUp(base.main)
            if let sec = base.secondary { other.warmUp(sec) }
            let total = 4.5
            for voiceSpeed in [1.0, 1.5, 2.0, 3.0, 4.0] {
                var s = base
                s.boost = max(total / voiceSpeed, 1)
                let ssml = "<speak><prosody rate=\"\(Int(voiceSpeed * 100))%\">\(long)</prosody></speak>"
                measure(String(format: "voice at %.1fx, boost %.2f", voiceSpeed, s.boost)) { got in
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
            DiagnosticLog.write("bench: done")
        }.start()
    }

    /// `mixBench`: VoiceOver-like requests that mix Chinese and English, without boost, at VoiceOver's normal and fastest
    /// rate, read as the extension reads them (a piece per voice) and by the main voice alone (as VoiceOver's own voice
    /// would read them, the English included).
    static func mixed() {
        Thread {
            let items: [[String]] = [["打开Safari浏览器", "按钮"], ["张三：明天的 meeting 改到 3 点，记得带 MacBook 和 iPad。"],
                                     ["微信 WeChat，有 5 条未读消息"], ["Wi-Fi 设置", "按钮"], ["今天下午三点在会议室开会", "按钮"]]
            var scheme = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) && $0.secondary != nil } ?? VoiceScheme.defaultTingting
            scheme.boost = 1
            var alone = scheme
            alone.secondary = nil
            // split by language as with two voices, but the main voice reads the other pieces too
            var split = scheme
            split.secondary = scheme.main
            let main = SystemVoice(), other = SystemVoice(), twin = SystemVoice()
            main.warmUp(scheme.main)
            twin.warmUp(scheme.main)
            if let sec = scheme.secondary { other.warmUp(sec) }
            DiagnosticLog.write("bench: \(scheme.main.id) + \(scheme.secondary?.id ?? "none")")
            for rate in [100, 400] {
                let requests = items.map { parts in
                    "<speak><prosody rate=\"\(rate)%\">" + parts.map { "<s><lang xml:lang=\"cmn-CN\">\($0)</lang></s>" }.joined() + "</prosody></speak>"
                }
                for (label, s, o) in [("two voices", scheme, other), ("split, main voice", split, twin), ("main voice alone", alone, other),
                                      ("two voices", scheme, other), ("split, main voice", split, twin), ("main voice alone", alone, other)] {
                    measure("\(items.count) items at \(rate)%, \(label)") { got in
                        var n = 0
                        for r in requests {
                            if BoostAudioUnit.beforeIOS27 {
                                _ = BoostSynthesis.runPerVoice(ssml: r, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                               main: main, other: o, isCancelled: { false }) { n += $0.count }
                            } else {
                                _ = BoostSynthesis.runPieces(ssml: r, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                             main: main, other: o, isCancelled: { false }) { n += $0.count }
                            }
                        }
                        got += n
                    }
                }
            }
            DiagnosticLog.write("bench: done")
        }.start()
    }

    /// The sound cache: the mixed items of `mixed` with two voices, each read again and again, with and without it; and
    /// whether what comes from it sounds exactly like reading anew.
    static func cached() {
        Thread {
            let items: [[String]] = [["打开Safari浏览器", "按钮"], ["张三：明天的 meeting 改到 3 点，记得带 MacBook 和 iPad。"],
                                     ["微信 WeChat，有 5 条未读消息"], ["Wi-Fi 设置", "按钮"], ["今天下午三点在会议室开会", "按钮"]]
            var scheme = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) && $0.secondary != nil } ?? VoiceScheme.defaultTingting
            scheme.boost = 1
            let main = SystemVoice(), other = SystemVoice()
            main.warmUp(scheme.main)
            if let sec = scheme.secondary { other.warmUp(sec) }
            for rate in [100, 400] {
                let requests = items.map { parts in
                    "<speak><prosody rate=\"\(rate)%\">" + parts.map { "<s><lang xml:lang=\"cmn-CN\">\($0)</lang></s>" }.joined() + "</prosody></speak>"
                }
                func read(_ cache: SoundCache?, boost: Double = 1) -> [Float] {
                    var out: [Float] = []
                    var s = scheme
                    s.boost = boost
                    for r in requests {
                        if BoostAudioUnit.beforeIOS27 {
                            _ = BoostSynthesis.runPerVoice(ssml: r, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                           main: main, other: other, cache: cache, isCancelled: { false }) { out += $0 }
                        } else {
                            _ = BoostSynthesis.runPieces(ssml: r, scheme: s, settings: BoostSettings.shared(), rules: RuleBook.shared(),
                                                         main: main, other: other, cache: cache, isCancelled: { false }) { out += $0 }
                        }
                    }
                    return out
                }
                func differ(_ a: [Float], _ b: [Float]) -> String {
                    a.count != b.count ? "\(a.count) vs \(b.count) samples" : String(format: "largest difference %.6f", zip(a, b).map { abs($0 - $1) }.max() ?? 0)
                }
                let cache = SoundCache()
                let plain = read(nil), again = read(nil), first = read(cache), kept = read(cache)
                DiagnosticLog.write("bench \(rate)%: read twice: \(differ(plain, again)); with the cache, first time: \(differ(plain, first)); from the cache: \(differ(plain, kept))")
                // sped up: the sound from the cache goes through Sonic in other blocks than the voice's
                let fast = read(nil, boost: 4.5), fastKept = read(cache, boost: 4.5)
                DiagnosticLog.write("bench \(rate)%, boost 4.5: from the cache: \(differ(fast, fastKept))")
                for (label, c) in [("no cache", nil), ("cache", cache), ("no cache", nil), ("cache", cache)] as [(String, SoundCache?)] {
                    measure("\(items.count) items at \(rate)%, \(label)") { got in
                        got += read(c).count
                    }
                }
            }
            DiagnosticLog.write("bench: done")
        }.start()
    }

    /// `placeBench`: where the system voice's work runs (the share on the performance cores) and what it costs, with the
    /// synthesizer made and used on a thread of each QoS, and with this process's main thread (where the synthesizer
    /// reports) lowered as well. VoiceOver's own voice process runs the same frameworks mostly on the efficiency cores.
    static func placement() {
        let texts = ["张三，明天的会议改到下午三点，记得带电脑", "打开设置按钮", "今天下午三点在会议室开会，请大家准时参加，带上上周的报告和电脑。"]
        let scheme = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) } ?? VoiceScheme.defaultTingting
        let rate = AVSpeechUtteranceMaximumSpeechRate
        func run(_ label: String, _ qos: qos_class_t) {
            let done = DispatchSemaphore(value: 0)
            Thread {
                pthread_set_qos_class_self_np(qos, 0)
                let sv = SystemVoice()
                if let v = sv.resolve(scheme.main) {
                    _ = sv.speak(texts[0], voice: v, rate: rate, pitch: 1, isCancelled: { false }) { _ in } // loaded
                    var firsts: [Double] = []
                    measure(label) { got in
                        for t in texts {
                            let t0 = Date()
                            var first: Double?
                            _ = sv.speak(t, voice: v, rate: rate, pitch: 1, isCancelled: { false }) {
                                if first == nil { first = Date().timeIntervalSince(t0) }
                                got += $0.count
                            }
                            firsts.append(first ?? 0)
                        }
                    }
                    DiagnosticLog.write(String(format: "bench   first sound after %.1f ms on average", firsts.reduce(0, +) / Double(max(firsts.count, 1)) * 1000))
                }
                done.signal()
            }.start()
            done.wait()
        }
        Thread {
            run("made and read at user-initiated", QOS_CLASS_USER_INITIATED)
            run("made and read at utility", QOS_CLASS_UTILITY)
            run("made and read at background", QOS_CLASS_BACKGROUND)
            let lowered = DispatchQueue.main.sync { pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0) }
            DiagnosticLog.write("bench: main thread to utility: \(lowered == 0 ? "done" : "refused (\(lowered))")")
            run("main thread at utility, made and read at user-initiated", QOS_CLASS_USER_INITIATED)
            run("main thread at utility, made and read at utility", QOS_CLASS_UTILITY)
            _ = DispatchQueue.main.sync { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }
            run("made and read at user-initiated", QOS_CLASS_USER_INITIATED)
            DiagnosticLog.write("bench: done")
        }.start()
    }

    /// Runs `body` 20 times; logs the process's processor time and energy per run, the share of that time on the
    /// performance cores, and the sound it made.
    private static func measure(_ what: String, _ body: (inout Int) -> Void) {
        let n = 20
        var sound = 0
        let u0 = Usage(), t0 = Date()
        for _ in 0..<n { body(&sound) }
        let d = Usage().minus(u0)
        let wall = Date().timeIntervalSince(t0) * 1000 / Double(n)
        DiagnosticLog.write(String(format: "bench %@: %.1f ms CPU (%.0f%% on P cores), %.2f mJ, %.1f ms wall per run",
                                   what, d.cpu * 1000 / Double(n), d.pShare * 100, d.energy * 1000 / Double(n), wall)
            + (sound > 0 ? String(format: ", %.2f s of sound", Double(sound / n) / Double(SystemVoice.sampleRate)) : "")
            + ", by QoS " + d.byQoS)
    }

    /// The process's counters (`proc_pid_rusage`, not in the iOS headers).
    private struct Usage {
        var cpu = 0.0, pCPU = 0.0, energy = 0.0 // s, s, J
        var qos: [(String, Double)] = []

        init() {
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) { procPidRusage(getpid(), 6 /* RUSAGE_INFO_V6 */, UnsafeMutableRawPointer($0)) } == 0
            guard ok else { return }
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            func sec(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 }
            cpu = sec(ri.ri_user_time + ri.ri_system_time)
            pCPU = sec(ri.ri_user_ptime + ri.ri_system_ptime)
            energy = Double(ri.ri_energy_nj) / 1e9
            qos = [("UI", ri.ri_cpu_time_qos_user_interactive), ("IN", ri.ri_cpu_time_qos_user_initiated),
                   ("DEF", ri.ri_cpu_time_qos_default), ("UT", ri.ri_cpu_time_qos_utility),
                   ("BG", ri.ri_cpu_time_qos_background), ("MT", ri.ri_cpu_time_qos_maintenance),
                   ("LEG", ri.ri_cpu_time_qos_legacy)].map { ($0.0, sec($0.1)) }
        }

        func minus(_ o: Usage) -> Usage {
            var d = self
            d.cpu -= o.cpu; d.pCPU -= o.pCPU; d.energy -= o.energy
            d.qos = zip(qos, o.qos).map { ($0.0, $0.1 - $1.1) }
            return d
        }

        var pShare: Double { cpu > 0 ? pCPU / cpu : 0 }
        var byQoS: String {
            let total = qos.reduce(0) { $0 + $1.1 }
            return qos.filter { $0.1 > total * 0.02 }.map { String(format: "%@ %.0f%%", $0.0, $0.1 / max(total, 1e-9) * 100) }.joined(separator: " ")
        }
    }
}

@_silgen_name("proc_pid_rusage")
private func procPidRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32
#endif
