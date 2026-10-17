// Runs the extension's pipeline for one scheme (rules -> bilingual split -> system voices -> trim -> Sonic/WSOLA) on the
// Mac's own system voices and writes WAV files to listen to, plus timings:
//
//   swift run -c release render-samples [--voice <main Apple voice id>] [--secondary <Apple voice id> | --secondary none]
//                                       [--vo 50,100] [--boosts 1,2,3] [--rules <shared .voassist/.json>] [--balance]
//                                       [--numbers system|values|digits]
//                                       [--text <text>] [--ssml <a VoiceOver request>] [--out <dir>] [--calibrate] [--cancel-test]
//                                       [--switch-delay <ms>] [--switch-pause <ms>]
//
// `--vo` is VoiceOver's rate slider in percent (100 = the system voices' fastest), `--boosts` the scheme's speed boost.
// Every combination is written to <out>/vo<percent>_x<boost>.wav. `--switch-delay` pretends the system voice takes that
// long to switch voices (as on a phone); the line printed for each file then says where real-time playback would run dry.
import AVFoundation
import BoostCore

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func numbers(_ s: String?, _ fallback: [Double]) -> [Double] {
    s.map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
}

func entry(_ id: String) -> VoiceEntry? {
    guard let v = AVSpeechSynthesisVoice(identifier: id) else { return nil }
    return VoiceEntry(id: v.identifier, name: v.name, lang: v.language)
}

let mainID = arg("--voice") ?? VoiceEntry.tingting.id
let text = arg("--text") ?? "设置，按钮。轻点两下以打开 Safari 浏览器。今天天气很好，我们一起去公园散步，然后回家吃饭。"
let outDir = URL(fileURLWithPath: arg("--out") ?? "samples")
let vos = numbers(arg("--vo"), [50, 100])
let boosts = numbers(arg("--boosts"), [1, 2, 3])

Thread {
    let voice = SystemVoice()
    voice.debugSwitchDelay = Double(arg("--switch-delay") ?? "0").map { $0 / 1000 } ?? 0
    guard let main = entry(mainID), voice.resolve(main) != nil else {
        print("voice \(mainID) is not available"); exit(1)
    }
    let secondaryID = arg("--secondary") ?? (VoiceScheme.secondaryReadsEnglish(main: main.lang) ? VoiceEntry.samantha.id : VoiceEntry.tingting.id)
    var scheme = VoiceScheme(name: main.name, main: main, secondary: secondaryID == "none" ? nil : entry(secondaryID))
    if let n = arg("--numbers") {
        guard let r = NumberReading(rawValue: n) else { print("--numbers: system, values or digits"); exit(1) }
        scheme.numbers = r
    }
    if let p = arg("--switch-pause").flatMap(Int.init) { ApplePlanner.switchPauseMs = p } // the pause at voice switches, ms at normal speed
    print("scheme: main \(main.id) (\(main.lang)), secondary \(scheme.secondary?.id ?? "none")")
    var settings = BoostSettings()
    var rules = RuleBook([])
    if let path = arg("--rules") {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8), let bundle = ShareBundle.parse(t) else {
            print("cannot read rules from \(path)"); exit(1)
        }
        rules = RuleBook(bundle.rules ?? [])
        print("rules: \((bundle.rules ?? []).filter(\.enabled).count) enabled")
    }
    if CommandLine.arguments.contains("--balance"), let other = scheme.secondary,
       let a = Loudness.measure(voice: voice, entry: main), let b = Loudness.measure(voice: voice, entry: other) {
        scheme.balanceVolume = true
        scheme.secondaryGainDB = Loudness.balanceDB(main: a, secondary: b)
        print(String(format: "loudness: main %.1f dBFS, secondary %.1f dBFS -> secondary %+.1f dB", a, b, scheme.secondaryGainDB!))
    }
    print("pieces:", BoostSynthesis.pieces(text, scheme: scheme, rules: rules).map { "[\($0.voice)] \($0.text)" }.joined(separator: " | "))
    if CommandLine.arguments.contains("--calibrate") {
        let t0 = Date()
        if let m = RateMap.calibrate(voice: voice, entry: main) {
            print(String(format: "calibrated in %.2f s:", Date().timeIntervalSince(t0)), m.points.map { "\($0[0])→\($0[1])" }.joined(separator: " "))
            settings.rateMap = m
        } else {
            print("calibration failed")
        }
    }
    voice.warmUp(main)
    if let other = scheme.secondary { voice.warmUp(other) }
    if CommandLine.arguments.contains("--cancel-test") {
        // VoiceOver interrupts all the time: cancel mid-utterance, then the next request must come out whole at once.
        let v = voice.resolve(main)!
        let long = String(repeating: "这是一段很长的文字，用来测试中途打断。", count: 8)
        for round in 0..<20 {
            var got = 0
            var cancelAt = 0
            let r1 = voice.speak(long, voice: v, rate: 0.7, pitch: 1, isCancelled: { got > 2000 + round * 300 }) { got += $0.count; cancelAt = got }
            var n2 = 0
            let t0 = Date()
            var first = -1.0
            let r2 = voice.speak("下一句", voice: v, rate: 0.7, pitch: 1, isCancelled: { false }) {
                if first < 0 { first = Date().timeIntervalSince(t0) }
                n2 += $0.count
            }
            print("round \(round): first \(r1) after \(cancelAt) samples; next \(r2) \(n2) samples, first audio \(Int(first * 1000)) ms")
        }
        exit(0)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let ssmlArg = arg("--ssml") // a whole request as VoiceOver would send it, instead of --text and --vo
    if let s = ssmlArg { print("plan:", ApplePlanner.plan(s, scheme: scheme, rules: rules, map: settings.effectiveRateMap)) }
    for vo in ssmlArg == nil ? vos : [0] {
        for boost in boosts {
            scheme.boost = boost
            let ssml = ssmlArg ?? VoiceOverRate.previewSSML(text, percent: vo)
            let plan = ApplePlanner.plan(ssml, scheme: scheme, rules: rules, map: settings.effectiveRateMap)
            var out: [Float] = []
            var firstAudio: TimeInterval = -1
            var playback = PlaybackCheck()
            let t0 = Date()
            let status = BoostSynthesis.run(ssml: ssml, scheme: scheme, settings: settings, rules: rules, voice: voice, isCancelled: { false },
                                            switching: { playback.setSwitching($0) }) { pcm in
                if firstAudio < 0, pcm.contains(where: { $0 != 0 }) { firstAudio = Date().timeIntervalSince(t0) }
                playback.add(pcm.count)
                out += pcm
            }
            playback.finish()
            let wall = Date().timeIntervalSince(t0)
            let name = String(format: "vo%g_x%g.wav", vo, boost)
            try? WAV.data(out, sampleRate: SystemVoice.sampleRate).write(to: outDir.appendingPathComponent(name))
            print(String(format: "%@ VoiceOver %g%% (voice speed %.2fx, %d stretches) × boost %g: %.2f s audio, first sound after %.0f ms, synthesis %.0f ms, %@; voice switches %@ ms; playback: %@",
                         name, vo, plan.speed, plan.segments.count, boost, Double(out.count) / Double(SystemVoice.sampleRate),
                         firstAudio * 1000, wall * 1000, "\(status)", voice.lastSwitchWaitsMs.map(String.init).joined(separator: "/"), playback.summary))
        }
    }
    print("WAV files in \(outDir.path)")
    exit(0)
}.start()

// AVSpeechSynthesizer.write delivers on the main queue: keep it free.
RunLoop.main.run()
