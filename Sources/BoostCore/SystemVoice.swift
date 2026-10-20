import AVFoundation

/// Thread-safe hand-over of PCM from `AVSpeechSynthesizer.write`'s callback to the thread waiting in `speak`. Every
/// chunk carries the number of the voice stretch it belongs to: the synthesizer ends each stretch of one voice with an
/// empty buffer, and only `didFinish` says the utterance is over (an utterance that switches voices has several).
private final class ChunkBox {
    private let cond = NSCondition()
    private var chunks: [([Float], Int)] = []
    private var segment = 0
    private var finished = false
    private var abandoned = false
    private var woken = false
    private(set) var lastNews = Date()
    /// When the callbacks came (diagnostics): the first and the last sound, the last end of a stretch, didFinish.
    private(set) var firstSoundAt: Date?, lastSoundAt: Date?, endAt: Date?, finishedAt: Date?
    private(set) var soundChunks = 0

    /// Some sound has come.
    var hasSound: Bool {
        cond.lock(); defer { cond.unlock() }
        return firstSoundAt != nil
    }

    /// The callback times (see above), read together.
    func times() -> (first: Date?, last: Date?, end: Date?, finished: Date?, chunks: Int) {
        cond.lock(); defer { cond.unlock() }
        return (firstSoundAt, lastSoundAt, endAt, finishedAt, soundChunks)
    }

    func push(_ c: [Float]) {
        cond.lock(); defer { cond.unlock() }
        lastNews = Date()
        guard !abandoned, !c.isEmpty else { return }
        if firstSoundAt == nil { firstSoundAt = lastNews }
        lastSoundAt = lastNews
        soundChunks += 1
        chunks.append((c, segment))
        cond.signal()
    }

    /// An empty buffer: the stretch of one voice ended.
    func endOfStretch() {
        cond.lock(); defer { cond.unlock() }
        lastNews = Date()
        endAt = lastNews
        segment += 1
        cond.signal()
    }

    func finish() {
        cond.lock(); defer { cond.unlock() }
        finished = true
        finishedAt = Date()
        cond.signal()
    }

    func abandon() {
        cond.lock(); defer { cond.unlock() }
        abandoned = true
    }

    /// Ends the current wait at once (a request came: the reader looks whether its utterance was cut short).
    func wake() {
        cond.lock(); defer { cond.unlock() }
        woken = true
        cond.signal()
    }

    /// Waits up to `timeout` for news; returns the chunks so far, the stretches ended so far, whether `didFinish` came,
    /// and how long ago anything came.
    func take(timeout: TimeInterval) -> ([([Float], Int)], Int, Bool, TimeInterval) {
        cond.lock(); defer { cond.unlock() }
        if chunks.isEmpty && !finished && !woken { _ = cond.wait(until: Date(timeIntervalSinceNow: timeout)) }
        woken = false
        let c = chunks
        chunks.removeAll()
        return (c, segment, finished, Date().timeIntervalSince(lastNews))
    }
}

/// How long the main queue took at most to run a block sent to it (diagnostics, see `SystemVoice.reportSlowEnd`).
final class MainQueueLag {
    private let lock = NSLock()
    private var worst = 0.0

    var maxMs: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(worst * 1000)
    }

    func ping() {
        let sent = Date()
        DispatchQueue.main.async { [self] in
            let d = Date().timeIntervalSince(sent)
            lock.lock(); worst = max(worst, d); lock.unlock()
        }
    }
}

/// Routes the synthesizer's `didFinish` / `didCancel` to the utterance's box (delegate calls arrive on the main queue).
private final class FinishRouter: NSObject, AVSpeechSynthesizerDelegate {
    private let lock = NSLock()
    private var boxes: [ObjectIdentifier: ChunkBox] = [:]

    func register(_ u: AVSpeechUtterance, _ box: ChunkBox) {
        lock.lock(); boxes[ObjectIdentifier(u)] = box; lock.unlock()
    }

    /// Every utterance's end, finished or cancelled.
    var onDone: (() -> Void)?

    private func done(_ u: AVSpeechUtterance) {
        lock.lock(); let box = boxes.removeValue(forKey: ObjectIdentifier(u)); lock.unlock()
        onDone?() // first: the reader, told it is over, may hand this synthesizer the next utterance at once
        box?.finish()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done(u) }
}

/// Converts whatever the system voice delivers (Float32 or Int16, 22.05 kHz for the compact voices, other rates for some
/// others) to mono Float32 at `SystemVoice.sampleRate`.
private final class PCMAdapter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?

    init(sampleRate: Int) {
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    }

    func convert(_ b: AVAudioPCMBuffer) -> [Float] {
        let f = b.format
        if f.commonFormat == .pcmFormatFloat32, f.sampleRate == target.sampleRate, f.channelCount == 1, let d = b.floatChannelData {
            return Array(UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
        }
        if converter == nil || from != f {
            converter = AVAudioConverter(from: f, to: target)
            from = f
        }
        return run(b, end: false)
    }

    /// The resampler's look-ahead at the end of the utterance.
    func finish() -> [Float] {
        guard converter != nil else { return [] }
        let out = run(nil, end: true)
        converter = nil
        return out
    }

    private func run(_ b: AVAudioPCMBuffer?, end: Bool) -> [Float] {
        guard let conv = converter else { return [] }
        let inFrames = Double(b?.frameLength ?? 0)
        let cap = AVAudioFrameCount(inFrames * target.sampleRate / (from?.sampleRate ?? target.sampleRate)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var given = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if let b = b, !given {
                given = true
                status.pointee = .haveData
                return b
            }
            status.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        guard let d = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }
}

/// The Apple voices, through `AVSpeechSynthesizer.write` (iOS 13+): the PCM comes back to us instead of being played.
///
/// `write`'s callbacks arrive on the MAIN queue (measured on macOS 27: with the main thread blocked they never come, from
/// whichever thread the synthesizer was made or called on). So `speak` must run on a background thread, and nothing may
/// hold the main thread while it waits.
public final class SystemVoice {
    /// The rate of everything that leaves this class (the compact voices' own rate, so normally nothing is resampled).
    public static let sampleRate = 22050

    private var synth: AVSpeechSynthesizer?
    private let router = FinishRouter()
    private var cache: [String: AVSpeechSynthesisVoice] = [:]
    private let lock = NSLock()
    private var current: ChunkBox? // the utterance being read, for `wake`
    private var inFlight = 0       // utterances handed over whose end has not been reported yet

    public init() {
        router.onDone = { [weak self] in self?.ended() }
    }

    private func ended() {
        lock.lock(); inFlight = max(inFlight - 1, 0); lock.unlock()
    }

    /// When an utterance here was last cut short.
    public private(set) var stoppedAt: Date?

    /// Still working on an utterance: one cut short goes on for a while after the stop (its didCancel came 260-345 ms
    /// later on an iPad with iPadOS 26.7), and the next utterance waits for it.
    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0
    }

    /// The system voices this synthesizer has read an utterance with: loaded, their next one starts without the load.
    public private(set) var loadedVoices = Set<String>()

    /// Makes a reader waiting in `speak` look at once whether its utterance was cut short (from any thread).
    public func wake() {
        lock.lock(); let b = current; lock.unlock()
        b?.wake()
    }

    /// True on a thread while it hands an utterance to the system synthesizer (`write`), and only then (see
    /// `AnnouncementGuard` in the extension).
    public static var isHandingOver: Bool { Thread.current.threadDictionary[handingOverKey] != nil }
    private static let handingOverKey = "voassist.handingOver"

    private var synthesizer: AVSpeechSynthesizer {
        if let s = synth { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = router
        synth = s
        return s
    }

    /// The Apple voice behind `entry`, or the language's default Apple voice when that one is not installed. Never a
    /// third-party voice: that would be a provider again (this very extension, at worst).
    public func resolve(_ entry: VoiceEntry) -> AVSpeechSynthesisVoice? {
        if let v = cache[entry.id] { return v }
        var v = AVSpeechSynthesisVoice(identifier: entry.id)
        if v == nil || !VoiceEntry.isWrappable(v!.identifier) { v = AVSpeechSynthesisVoice(language: entry.lang) }
        guard let voice = v, VoiceEntry.isWrappable(voice.identifier) else { return nil }
        cache[entry.id] = voice
        return voice
    }

    public enum Outcome: Equatable { case done, cancelled, timedOut, rejected }

    /// How the last utterance was known to be over (diagnostics): "didFinish", or "quiet" when it never came.
    public private(set) var lastEnd = ""

    /// How long the system voice took at each voice switch of the last utterance (ms, from the end of one voice's
    /// stretch to the next voice's first audio).
    public private(set) var lastSwitchWaitsMs: [Int] = []

    /// Development: pretend the system voice takes this long to switch voices (as it may on a phone), to hear what the
    /// listener gets then (`render-samples --switch-delay`).
    public var debugSwitchDelay: TimeInterval = 0

    /// Synthesizes plain `text` and hands the PCM to `onPCM` (on the calling thread) as it comes. Blocks until the
    /// utterance is complete, `isCancelled` turns true, or nothing arrives for `stallTimeout` seconds (`soundStall` once
    /// it has sounded). Not on the main thread.
    public func speak(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float, pitch: Float, stallTimeout: TimeInterval = 4,
                      isCancelled: () -> Bool, onPCM: ([Float]) -> Void) -> Outcome {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        u.pitchMultiplier = min(max(pitch, 0.5), 2)
        return run(u, voices: [voice.identifier], stretches: 1, stallTimeout: stallTimeout, isCancelled: isCancelled) { pcm, _ in onPCM(pcm) }
    }

    /// Synthesizes SSML with `voice` as the main voice; `onPCM` gets each chunk with the number of the voice stretch it
    /// belongs to (0, 1, ... as `<voice>` switches come), and an empty chunk with the next number as soon as a stretch
    /// ends (before the next voice has made a sound). `stretches` is how many there should be: a fallback for knowing
    /// the end if `didFinish` never came. `.rejected` if the system voice does not take the SSML. `others`: the voices
    /// the SSML switches to (`<voice name>`).
    public func speak(ssml: String, voice: AVSpeechSynthesisVoice, others: [String] = [], stretches: Int,
                      stallTimeout: TimeInterval = 4, isCancelled: () -> Bool, onPCM: ([Float], Int) -> Void) -> Outcome {
        guard let u = AVSpeechUtterance(ssmlRepresentation: ssml) else { return .rejected }
        u.voice = voice
        return run(u, voices: [voice.identifier] + others, stretches: stretches, stallTimeout: stallTimeout,
                   isCancelled: isCancelled, onPCM: onPCM)
    }

    private func run(_ u: AVSpeechUtterance, voices: [String], stretches: Int, stallTimeout: TimeInterval,
                     isCancelled: () -> Bool, onPCM: ([Float], Int) -> Void) -> Outcome {
        u.volume = 1
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        let box = ChunkBox()
        let adapter = PCMAdapter(sampleRate: SystemVoice.sampleRate)
        let synth = synthesizer
        router.register(u, box)
        lock.lock(); current = box; inFlight += 1; lock.unlock()
        defer { lock.lock(); current = nil; lock.unlock() }
        #if LATENCY_PROBE
        LatencyTrace.mark("write")
        #endif
        Thread.current.threadDictionary[SystemVoice.handingOverKey] = true
        synth.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { // the end of one voice's stretch (or of everything)
                box.push(adapter.finish())
                box.endOfStretch()
            } else {
                box.push(adapter.convert(pcm))
            }
        }
        Thread.current.threadDictionary[SystemVoice.handingOverKey] = nil
        var reported = 0 // stretch ends passed on
        var voiced = 0    // the newest stretch whose sound was passed on
        var switchFrom: Date?
        lastSwitchWaitsMs = []
        // diagnostics: how late the end came, and whether the main queue (where the callbacks arrive) was held up
        let t0 = Date()
        let watch = DiagnosticLog.isOn
        let lag = MainQueueLag()
        var nextPing = t0
        func stretchEnded() {
            reported += 1
            if reported < stretches { switchFrom = Date() }
            onPCM([], reported)
        }
        while true {
            if watch && Date() >= nextPing {
                lag.ping()
                nextPing = Date().addingTimeInterval(0.05)
            }
            let (chunks, ended, finished, quiet) = box.take(timeout: 0.01)
            for (c, seg) in chunks {
                if isCancelled() { break }
                while reported < seg { stretchEnded() }
                if seg > voiced {
                    voiced = seg
                    if debugSwitchDelay > 0 { Thread.sleep(forTimeInterval: debugSwitchDelay) }
                    if let t = switchFrom { lastSwitchWaitsMs.append(Int(Date().timeIntervalSince(t) * 1000)) }
                    switchFrom = nil
                }
                onPCM(c, seg)
            }
            if isCancelled() {
                box.abandon()
                synth.stopSpeaking(at: .immediate) // returns at once; the synthesizer is busy a while longer (`isBusy`)
                stoppedAt = Date()
                return .cancelled
            }
            while reported < ended { stretchEnded() }
            // didFinish is the end; should it never come, all the expected stretches and a quiet second are
            if finished || (ended >= stretches && quiet > SystemVoice.soundStall) {
                lastEnd = finished ? "didFinish" : "quiet (\(ended) stretches)"
                if watch { SystemVoice.reportSlowEnd(box, since: t0, lag: lag, how: lastEnd) }
                loadedVoices.formUnion(voices)
                if !finished { lock.lock(); inFlight = 0; lock.unlock() } // its end will not be reported
                return .done
            }
            if quiet > stallTimeout || (quiet > SystemVoice.soundStall && box.hasSound) {
                if watch { SystemVoice.reportSlowEnd(box, since: t0, lag: lag, how: "stalled") }
                box.abandon()
                synth.stopSpeaking(at: .immediate)
                // a synthesizer that went quiet may stay stuck (every later request would wait it out too): a new one next
                self.synth = nil
                loadedVoices = []
                lock.lock(); inFlight = 0; lock.unlock()
                return .timedOut
            }
        }
    }

    /// How long an utterance that has sounded may go without news before it counts as stuck: the system voice sends an
    /// utterance at many times real time, block after block, but now and then stops short of its end, without its last
    /// blocks, the end of its stretch or didFinish (an iPad with iPadOS 26.7 under VoiceOver: about once in 45 items,
    /// 300 ms and more), and VoiceOver waits for it. Before, that wait lasted `stallTimeout` (4 s). Then what came is
    /// played, the item ends, and the synthesizer is replaced. Also the wait for didFinish after the last stretch.
    static let soundStall: TimeInterval = 0.3

    /// Diagnostics: an utterance whose end came late after its last sound (more than 80 ms) goes into the log, with when
    /// each kind of callback came and how long the main queue, where they arrive, was held up at most meanwhile.
    fileprivate static func reportSlowEnd(_ box: ChunkBox, since t0: Date, lag: MainQueueLag, how: String) {
        let t = box.times()
        guard let last = t.last else { return }
        guard (t.finished ?? Date()).timeIntervalSince(last) > 0.08 else { return }
        func ms(_ d: Date?) -> String { d.map { "\(Int($0.timeIntervalSince(t0) * 1000))" } ?? "-" }
        DiagnosticLog.write("slow end (\(how)): sound \(ms(t.first))-\(ms(last)) ms in \(t.chunks) chunks, stretch end \(ms(t.end)) ms, didFinish \(ms(t.finished)) ms; main queue held up \(lag.maxMs) ms at most")
    }

    /// Loads the voice and the synthesizer (the first utterance costs ~250 ms, later ones ~5 ms before the first audio).
    /// Where one synthesizer reads both voices (iOS 27), a secondary voice is loaded inside an utterance of its scheme's
    /// main voice (`within`): read on its own it would be the voice the synthesizer was left on, and the next request in
    /// the main voice would pay a voice switch first (3-27 ms on an iOS 27 iPhone; ~290 ms on the iOS 26.5 and 18.6
    /// simulators, where each voice now has synthesizers of its own). Stops when `isCancelled` turns true (a request
    /// came); true if it went through.
    @discardableResult
    public func warmUp(_ entry: VoiceEntry, within main: VoiceEntry? = nil, isCancelled: () -> Bool = { false }) -> Bool {
        guard let v = resolve(entry) else { return false }
        func word(_ lang: String) -> String { LanguageRuns.isChinese(lang) ? "好" : "a" }
        if let m = main, let mv = resolve(m), mv.identifier != v.identifier {
            let ssml = "<speak>\(word(m.lang))<voice name=\"\(v.identifier)\">\(word(entry.lang))</voice></speak>"
            return speak(ssml: ssml, voice: mv, others: [v.identifier], stretches: 2, stallTimeout: 2, isCancelled: isCancelled) { _, _ in } == .done
        }
        return speak(word(entry.lang), voice: v, rate: 0.5, pitch: 1, stallTimeout: 2, isCancelled: isCancelled) { _ in } == .done
    }
}

/// One whole request (all segments of the SSML) for a scheme: reading rules, bilingual split, the system voices, the
/// speed-up.
public enum BoostSynthesis {
    public enum Status: Equatable { case ok, cancelled, noVoice, timedOut }

    /// What a piece of text turns into before it is read: the rules applied (if the scheme uses them) and the numbers
    /// written out (if it asks for that), then split between the main and the secondary voice (if the scheme has one).
    public static func pieces(_ text: String, scheme: VoiceScheme, rules: RuleBook) -> [LanguageRun] {
        let t = scheme.prepared(text, rules: rules)
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        return scheme.secondary == nil ? [LanguageRun(t, .main)] : LanguageRuns.split(t, mainLanguage: scheme.main.lang)
    }

    /// Reads VoiceOver's SSML request with the scheme and emits mono Float32 at `SystemVoice.sampleRate`. The system
    /// voice reads the (rewritten) SSML itself, so pauses come out as when VoiceOver reads it; then the scheme's boost
    /// speeds everything up. `switching` hears true while a voice switch lies ahead of the audio so far (from the start of a
    /// request with several voices, and whenever one voice's stretch has come out whole), false once the next voice has
    /// sounded: the system voice can take a while to switch, and a player can make sure it has enough in hand meanwhile.
    public static func run(ssml: String, scheme: VoiceScheme, settings s: BoostSettings, rules: RuleBook, voice: SystemVoice,
                           isCancelled: () -> Bool, switching: ((Bool) -> Void)? = nil, emit: ([Float]) -> Void) -> Status {
        let sr = SystemVoice.sampleRate
        let map = s.effectiveRateMap
        guard let mainVoice = voice.resolve(scheme.main) else { return .noVoice }
        // the secondary voice as the system has it, like the main one: another voice of its language when that one is not
        // there (the SSML names it), none when its language has none
        var scheme = scheme
        if let o = scheme.secondary { scheme.secondary = voice.resolve(o).map { VoiceEntry(id: $0.identifier, name: o.name, lang: o.lang) } }
        var plan = ApplePlanner.plan(ssml, scheme: scheme, rules: rules, map: map)
        #if LATENCY_PROBE
        LatencyTrace.mark("planned")
        #endif
        let proc = SegmentProcessor(sampleRate: sr, stretch: scheme.boost,
                                    trimLeading: !plan.keepLeading, trimTrailing: !plan.keepTrailing)
        let otherGain = scheme.secondaryGain
        var stretch = 0
        var switchTo: Int? // the stretch whose sound ends the voice switch ahead
        var heardSinceSwitch = 0 // output of that stretch so far
        func read(_ p: ApplePlan) -> SystemVoice.Outcome {
            if p.segments.count > 1 {
                switchTo = 1
                switching?(true)
            }
            let others = p.segments.contains(.other) ? scheme.secondary.map { [$0.id] } ?? [] : []
            return voice.speak(ssml: p.ssml, voice: mainVoice, others: others, stretches: max(p.segments.count, 1),
                               isCancelled: isCancelled) { pcm, seg in
                // a voice switch: the stretch before comes out whole right away, with only the pause its punctuation
                // asks for (the end of the last stretch is the end of the request: `finish` below)
                while stretch < seg {
                    if stretch < p.switchCapMs.count {
                        emit(proc.endStretch(capMs: p.switchCapMs[stretch]))
                        if switchTo == nil { switching?(true) }
                        switchTo = stretch + 1
                        heardSinceSwitch = 0
                    }
                    stretch += 1
                }
                guard !pcm.isEmpty else { return }
                #if LATENCY_PROBE
                LatencyTrace.mark("engine audio")
                #endif
                let isOther = p.segments.indices.contains(seg) && p.segments[seg] == .other
                var x = pcm
                if isOther && otherGain != 1 { applyGain(&x, otherGain) }
                let out = proc.push(x)
                emit(out)
                // the switch is over once the next voice has really got going: its first buffer can be tiny and the rest
                // come tens of ms later on a phone, so a block of the host's worth of its sound, not just its first buffer
                if let t = switchTo, seg >= t {
                    heardSinceSwitch += out.count
                    if heardSinceSwitch >= AudioRing.defaultBlock {
                        switchTo = nil
                        switching?(false)
                    }
                }
            }
        }
        var r = read(plan)
        if r == .rejected {
            // the system voice did not take VoiceOver's SSML as rewritten: our own plain version of it
            plan = ApplePlanner.plan(ApplePlanner.rebuild(SSML.parse(ssml)), scheme: scheme, rules: rules, map: map)
            r = read(plan)
        }
        if switchTo != nil {
            switchTo = nil
            switching?(false)
        }
        switch r {
        case .cancelled: return .cancelled
        case .rejected: return .timedOut
        case .timedOut:
            emit(proc.finish())
            return .timedOut
        case .done: break
        }
        emit(proc.finish())
        // With the voice's own trailing silence trimmed, two requests played back to back (VoiceOver's item name, then
        // its hint) would run together: a short gap, as short as the speaking speed makes the voice's own pauses.
        if plan.hasText && !plan.keepTrailing {
            let speed = plan.speed * scheme.boost
            emit([Float](repeating: 0, count: Int(0.1 / max(speed, 1) * Double(sr))))
        }
        return .ok
    }
}

extension BoostSynthesis {
    /// iOS 27: VoiceOver's request as the system voice reads it (`ApplePlanner`, its pauses as when VoiceOver reads that
    /// voice itself), a piece per stretch of one voice, each read whole by its voice's own synthesizer (`main`, `other`).
    /// One synthesizer switching voices inside an utterance took 3-27 ms per switch on an iPhone Air, and the player held
    /// back 300 ms of sound before starting a request with a switch ahead, lest it ran dry while the voice changed: mixed
    /// items sounded after 58-70 ms against 24-48 ms. A piece starts on an idle synthesizer with its voice loaded.
    /// Short pieces read before come from `cache`, if given.
    public static func runPieces(ssml: String, scheme: VoiceScheme, settings s: BoostSettings, rules: RuleBook,
                                 main mainSynth: SystemVoice, other otherSynth: SystemVoice, cache: SoundCache? = nil,
                                 isCancelled: () -> Bool, emit: ([Float]) -> Void) -> Status {
        let sr = SystemVoice.sampleRate
        let map = s.effectiveRateMap
        guard let mainVoice = mainSynth.resolve(scheme.main) else { return .noVoice }
        // the secondary voice as the system has it, like the main one (see `run`)
        var scheme = scheme
        if let o = scheme.secondary { scheme.secondary = otherSynth.resolve(o).map { VoiceEntry(id: $0.identifier, name: o.name, lang: o.lang) } }
        let otherVoice = scheme.secondary.flatMap { otherSynth.resolve($0) }
        let plan = ApplePlanner.plan(ssml, scheme: scheme, rules: rules, map: map)
        let proc = SegmentProcessor(sampleRate: sr, stretch: scheme.boost, trimLeading: !plan.keepLeading, trimTrailing: !plan.keepTrailing)
        let otherGain = scheme.secondaryGain
        let pitch = SSML.parse(ssml).pitch
        for (i, piece) in plan.pieces.enumerated() {
            if isCancelled() { return .cancelled }
            let other = piece.voice == .other && otherVoice != nil
            let synth = other ? otherSynth : mainSynth
            let voice = other ? otherVoice! : mainVoice
            func take(_ pcm: [Float]) {
                guard !pcm.isEmpty else { return }
                var x = pcm
                if other && otherGain != 1 { applyGain(&x, otherGain) }
                emit(proc.push(x))
            }
            let key = cache == nil ? nil : SoundCache.key(piece.text, voice: voice.identifier, reading: piece.ssml)
            if cache?.play(key, take) != true {
                var heard: [[Float]] = []
                let read = synth.speak(ssml: piece.ssml, voice: voice, stretches: 1, isCancelled: isCancelled) { pcm, _ in
                    if key != nil { heard.append(pcm) }
                    take(pcm)
                }
                var outcome = read
                if outcome == .rejected, LanguageRuns.speakable(piece.text) {
                    // the system voice did not take the piece as rewritten: its words, plainly
                    outcome = synth.speak(piece.text, voice: voice, rate: map.rate(for: min(piece.speed, map.maxMultiplier)), pitch: pitch,
                                          isCancelled: isCancelled) { take($0) }
                }
                switch outcome {
                case .cancelled: return .cancelled
                case .timedOut:
                    emit(proc.finish())
                    return .timedOut
                case .done, .rejected: if read == .done, let k = key { cache?.keep(k, heard) }
                }
            }
            if i < plan.pieces.count - 1, i < plan.switchCapMs.count { emit(proc.endStretch(capMs: plan.switchCapMs[i])) }
        }
        emit(proc.finish())
        // two requests played back to back apart a little, as in `run`
        if plan.hasText && !plan.keepTrailing {
            emit([Float](repeating: 0, count: Int(0.1 / max(plan.speed * scheme.boost, 1) * Double(sr))))
        }
        return .ok
    }

    /// Before iOS 27 a synthesizer that changes voices pays for it every time, between utterances as well as inside one:
    /// 20-65 ms per utterance on the iOS 26.5 simulator, against 1-2 ms with a synthesizer per voice (`-switchTest`), and
    /// 200-950 ms per request with a Latin word in a log from an iPad on iPadOS 26.7 (iOS 27: 1-2 ms either way). So there
    /// a request is read stretch by stretch, each language's stretches by a synthesizer of its own (`main`, `other`), as
    /// plain utterances. VoiceOver's requests there are short and simple (a name; at times a break and a second part;
    /// `<prosody volume pitch>`, a rate only away from VoiceOver's default one), so `SSML.parse` has all of it.
    /// Short stretches read before come from `cache`, if given.
    public static func runPerVoice(ssml: String, scheme: VoiceScheme, settings s: BoostSettings, rules: RuleBook,
                                   main mainSynth: SystemVoice, other otherSynth: SystemVoice, cache: SoundCache? = nil,
                                   isCancelled: () -> Bool, emit: ([Float]) -> Void) -> Status {
        let sr = SystemVoice.sampleRate
        let map = s.effectiveRateMap
        guard let mainVoice = mainSynth.resolve(scheme.main) else { return .noVoice }
        let otherVoice = scheme.secondary.flatMap { otherSynth.resolve($0) }
        let request = SSML.parse(ssml)
        let speed = min(max(request.rate, 0.1), map.maxMultiplier)
        let mainRate = map.rate(for: speed)
        let otherRate = map.rate(for: min(speed * scheme.secondaryRate, map.maxMultiplier))
        let segments = request.segments
        // a request that starts or ends with VoiceOver's own break keeps that silence (as `ApplePlan.keepLeading`)
        let keepLeading = segments.first.map { $0.text.isEmpty && $0.silenceMs > 0 } ?? false
        let keepTrailing = segments.last.map { $0.explicitBreak && $0.silenceMs > 0 } ?? false
        let proc = SegmentProcessor(sampleRate: sr, stretch: scheme.boost, trimLeading: !keepLeading, trimTrailing: !keepTrailing)
        let otherGain = scheme.secondaryGain
        for seg in segments {
            let text = scheme.prepared(seg.text, rules: rules)
            if LanguageRuns.speakable(text) {
                let runs = otherVoice == nil ? [LanguageRun(text, .main)] : LanguageRuns.split(text, mainLanguage: scheme.main.lang)
                for (i, run) in runs.enumerated() where !run.text.isEmpty {
                    if isCancelled() { return .cancelled }
                    let other = run.voice == .other && otherVoice != nil
                    var words = runs.count > 1 ? LanguageRuns.lowercasingLoneCapital(run.text) : run.text
                    let reader = other ? scheme.secondary?.lang : scheme.main.lang
                    if let lang = reader, !LanguageRuns.isChinese(lang) { words = LanguageRuns.westernPunctuation(words) }
                    let voice = other ? otherVoice! : mainVoice, rate = other ? otherRate : mainRate
                    func take(_ pcm: [Float]) {
                        var x = pcm
                        if other && otherGain != 1 { applyGain(&x, otherGain) }
                        emit(proc.push(x))
                    }
                    let key = cache == nil ? nil : SoundCache.key(words, voice: voice.identifier, reading: "\(rate) \(request.pitch)")
                    if cache?.play(key, take) != true {
                        var heard: [[Float]] = []
                        let outcome = (other ? otherSynth : mainSynth).speak(words, voice: voice, rate: rate, pitch: request.pitch,
                                                                              isCancelled: isCancelled) { pcm in
                            if key != nil { heard.append(pcm) }
                            take(pcm)
                        }
                        switch outcome {
                        case .cancelled: return .cancelled
                        case .timedOut, .rejected:
                            emit(proc.finish())
                            return .timedOut
                        case .done: if let k = key { cache?.keep(k, heard) }
                        }
                    }
                    // where the voices change: the pause its punctuation asks for, else none (as `ApplePlan.switchCapMs`)
                    if i < runs.count - 1 { emit(proc.endStretch(capMs: ApplePlanner.switchPause(after: words, speed: speed))) }
                }
            }
            // VoiceOver's break: silence, sped up with the rest
            if seg.silenceMs > 0 { emit(proc.push([Float](repeating: 0, count: sr * seg.silenceMs / 1000))) }
        }
        emit(proc.finish())
        // No gap after the last sound, unlike `run`: VoiceOver leaves ~50 ms between the parts of an item there, on top
        // of the audio (iPadOS 26.7 iPad), so a name and its "按钮" are apart enough.
        return .ok
    }
}

/// How loud a voice speaks, to match a secondary voice to the main one.
public enum Loudness {
    /// Mean power (dBFS) of the 20 ms frames above a -50 dBFS gate: the speech, not the pauses.
    public static func level(_ pcm: [Float], sampleRate: Int) -> Double? {
        let frame = sampleRate / 50
        var sum = 0.0
        var n = 0
        var i = 0
        while i + frame <= pcm.count {
            var e = 0.0
            for k in i..<(i + frame) { e += Double(pcm[k] * pcm[k]) }
            e /= Double(frame)
            if e > 1e-5 { // -50 dBFS
                sum += e
                n += 1
            }
            i += frame
        }
        return n > 0 ? 10 * log10(sum / Double(n)) : nil
    }

    /// A voice's level, from a sentence in its own language. Not on the main thread.
    public static func measure(voice: SystemVoice, entry: VoiceEntry) -> Double? {
        guard let v = voice.resolve(entry) else { return nil }
        let text = LanguageRuns.isChinese(v.language) ? "今天天气很好，我们一起去公园散步，然后回家吃饭。"
                                              : "The quick brown fox jumps over the lazy dog, then runs back home for dinner."
        var pcm: [Float] = []
        let r = voice.speak(text, voice: v, rate: 0.5, pitch: 1, isCancelled: { false }) { pcm += $0 }
        return r == .done ? level(pcm, sampleRate: SystemVoice.sampleRate) : nil
    }

    /// The gain (dB) that brings the secondary voice to the main one's level, within the scheme's limit.
    public static func balanceDB(main: Double, secondary: Double) -> Double {
        min(max(main - secondary, -VoiceScheme.maxBalanceDB), VoiceScheme.maxBalanceDB)
    }
}

extension RateMap {
    /// Measures the system voice's speed at each rate of `RateMap.measured`: the speech length at 0.5 divided by the length
    /// at that rate (leading/trailing silence trimmed). Takes about a second. Not on the main thread.
    public static func calibrate(voice: SystemVoice, entry: VoiceEntry) -> RateMap? {
        guard let v = voice.resolve(entry) else { return nil }
        let text = LanguageRuns.isChinese(v.language) ? "今天天气很好，我们一起去公园散步，然后回家吃饭。"
                                              : "The quick brown fox jumps over the lazy dog, then runs back home for dinner."
        func length(_ rate: Double) -> Int? {
            let t = Trimmer(sampleRate: SystemVoice.sampleRate)
            var n = 0
            let r = voice.speak(text, voice: v, rate: Float(rate), pitch: 1, isCancelled: { false }) { n += t.push($0).count }
            n += t.finish().count
            return r == .done && n > 0 ? n : nil
        }
        guard let base = length(0.5) else { return nil }
        var points: [[Double]] = []
        for p in RateMap.measured.points {
            let r = p[0]
            guard let n = r == 0.5 ? base : length(r) else { return nil }
            points.append([r, (Double(base) / Double(n) * 1000).rounded() / 1000])
        }
        return RateMap(points: points)
    }
}
