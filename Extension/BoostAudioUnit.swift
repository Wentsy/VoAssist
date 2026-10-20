import AVFoundation
import AudioToolbox
import os

private let log = Logger(subsystem: "com.zdyi.voassist", category: "voice")

/// Each call the system makes into the extension, its thread and how long it took: into the diagnostic log while the
/// user records one (and, in a development build, the device log as `VOASSIST-CALL`), to see what the host waits for
/// (around locking and waking the phone, say).
private func traced<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
    let t0 = Date()
    defer {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let thread = Thread.isMainThread ? "main" : "bg"
        #if DEBUG
        log.notice("VOASSIST-CALL \(what, privacy: .public) on \(thread, privacy: .public): \(ms) ms")
        #endif
        DiagnosticLog.write("call \(what) on \(thread): \(ms) ms")
    }
    return try body()
}

/// One persistent synthesis thread. `AVSpeechSynthesizer.write` reports on the main queue, so the waiting happens here,
/// never on the main thread. Only the newest request matters.
final class SynthWorker {
    struct Job {
        let ssml: String
        let scheme: VoiceScheme
        let gen: Int
        let ring: AudioRing
        var submitted = Date()
        /// The voice VoiceOver asked for (for the diagnostic log).
        var voice = ""
    }

    private let cond = NSCondition()
    private var pending: Job?
    /// The scheme in use: its voices are loaded while idle, in every synthesizer that may read them.
    private var warmScheme: (main: VoiceEntry, secondary: VoiceEntry?)?
    private var gaveUp = Set<String>() // warm-ups that failed for another reason than a request (worker thread only)
    private var stopping = false
    /// The synthesizers for the main voice and for the secondary one (`BoostSynthesis.runPieces`, `runPerVoice`), the
    /// one in use first (worker thread only), all loaded while idle. One whose utterance was cut short goes on
    /// working for a while (its didCancel came 260-345 ms after the stop on an iPad with iPadOS 26.7, for a long item),
    /// and a new utterance on it waits for that: the next item sounded after 211-322 ms there, 11-20 ms on an idle one.
    /// Fast swiping cuts nearly every item short, so a request goes to an idle one. A synthesizer made on the spot is no
    /// help: loading it took as long (231-288 ms). Each loaded one costs ~4 MB.
    private var mains = [SystemVoice(), SystemVoice(), SystemVoice()]
    private var others = [SystemVoice(), SystemVoice()]
    private var voice: SystemVoice { mains[0] }
    private var otherVoice: SystemVoice { others[0] }
    private let all: [SystemVoice] // for `wake` from the host's threads
    /// Before iOS 27 VoiceOver's requests are read as plain text (`BoostSynthesis.runPerVoice`), from then on as SSML.
    private let plainText = BoostAudioUnit.beforeIOS27

    init() {
        all = mains + others
    }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.name = "voassist-synth"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        cond.lock(); stopping = true; cond.signal(); cond.unlock()
    }

    func submit(_ job: Job) {
        cond.lock(); pending = job; cond.signal(); cond.unlock()
        for s in all { s.wake() } // the request being read notices at once that it was cut short
    }

    /// Puts an idle synthesizer first, one with `voice` loaded if there is one; with none idle, the one cut short first
    /// (the first to be done).
    private func idleFirst(_ pool: inout [SystemVoice], for voice: VoiceEntry?) {
        guard pool[0].isBusy else { return }
        let idle = pool.indices.filter { !pool[$0].isBusy }
        func loaded(_ i: Int) -> Bool {
            voice.flatMap { pool[i].resolve($0) }.map { pool[i].loadedVoices.contains($0.identifier) } ?? false
        }
        let pick = idle.first(where: loaded) ?? idle.first
            ?? pool.indices.min { (pool[$0].stoppedAt ?? .distantPast) < (pool[$1].stoppedAt ?? .distantPast) } ?? 0
        pool.insert(pool.remove(at: pick), at: 0)
    }

    /// Loads a scheme's voices in the background (a voice's first utterance is ~250 ms slower).
    func warm(_ main: VoiceEntry, secondary: VoiceEntry?) {
        cond.lock(); warmScheme = (main, secondary); cond.signal(); cond.unlock()
    }

    /// A request is waiting: a warm-up gives way to it.
    private var requestWaiting: Bool {
        cond.lock(); defer { cond.unlock() }
        return pending != nil || stopping
    }

    private func loop() {
        while true {
            cond.lock()
            while pending == nil && warmScheme == nil && !stopping { cond.wait() }
            if stopping { cond.unlock(); break }
            let job = pending
            pending = nil
            let scheme = job == nil ? warmScheme : nil
            cond.unlock()
            if let job = job {
                run(job)
                // VoiceOver may use any of our schemes: the one in use is loaded everywhere while idle
                cond.lock(); warmScheme = (job.scheme.main, job.scheme.secondary); cond.unlock()
            } else if let w = scheme {
                // one voice in one synthesizer at a time, so a request never waits for more than one warm-up
                if let next = nextWarmUp(main: w.main, secondary: w.secondary) {
                    if !next.run() && !requestWaiting { gaveUp.insert(next.key) }
                } else {
                    cond.lock()
                    if let c = warmScheme, c.main == w.main, c.secondary == w.secondary { warmScheme = nil }
                    cond.unlock()
                }
            }
        }
    }

    private struct WarmUp {
        let key: String
        let run: () -> Bool
    }

    /// The next voice to load: the main voice, then the secondary one, in the synthesizers in use, then in the others.
    private func nextWarmUp(main: VoiceEntry, secondary: VoiceEntry?) -> WarmUp? {
        var list: [(SystemVoice, VoiceEntry, VoiceEntry?)] = []
        for i in 0..<max(mains.count, others.count) {
            if i < mains.count { list.append((mains[i], main, nil)) }
            if let o = secondary, i < others.count { list.append((others[i], o, nil)) }
        }
        for (s, entry, within) in list where !s.isBusy {
            guard let id = s.resolve(entry)?.identifier, !s.loadedVoices.contains(id) else { continue }
            let key = "\(ObjectIdentifier(s).hashValue) \(id)"
            if gaveUp.contains(key) { continue }
            let n = (mains.firstIndex { $0 === s }).map { "main \($0)" } ?? (others.firstIndex { $0 === s }).map { "other \($0)" } ?? "?"
            return WarmUp(key: key) {
                let t0 = Date()
                let ok = s.warmUp(entry, within: within, isCancelled: { self.requestWaiting })
                DiagnosticLog.write("warm-up of \(id) in synthesizer \(n): \(ok ? "done" : "gave way") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                return ok
            }
        }
        return nil
    }

    private func run(_ job: Job) {
        let ring = job.ring, gen = job.gen
        guard ring.generation == gen else { return } // superseded before it started
        idleFirst(&mains, for: job.scheme.main)
        idleFirst(&others, for: job.scheme.secondary)
        let t0 = Date()
        #if LATENCY_PROBE
        LatencyTrace.mark("worker")
        #endif
        #if DEBUG
        // what VoiceOver sends, for `sudo log collect --device-udid <phone>` (the extension cannot write into the group)
        log.notice("VOASSIST-SSML \(job.scheme.name, privacy: .public) | \(String(job.ssml.prefix(400)), privacy: .public)")
        // the voice the scheme asks for, and the one the extension really gets
        log.notice("VOASSIST-VOICE \(job.scheme.name, privacy: .public): main \(job.scheme.main.id, privacy: .public) -> \(self.voice.resolve(job.scheme.main)?.identifier ?? "nil", privacy: .public); secondary \(job.scheme.secondary?.id ?? "-", privacy: .public) -> \(job.scheme.secondary.flatMap { self.voice.resolve($0)?.identifier } ?? "-", privacy: .public)")
        #endif
        let settings = BoostSettings.shared()
        #if LATENCY_PROBE
        LatencyTrace.mark("settings")
        #endif
        var firstAudio: Date?
        let out: ([Float]) -> Void = { pcm in
            #if LATENCY_PROBE
            if !pcm.isEmpty { LatencyTrace.mark("first output") }
            #endif
            if firstAudio == nil && !pcm.isEmpty { firstAudio = Date() }
            ring.append(pcm, gen: gen)
        }
        let status = plainText
            ? BoostSynthesis.runPerVoice(ssml: job.ssml, scheme: job.scheme, settings: settings, rules: RuleBook.shared(),
                                         main: voice, other: otherVoice, cache: SoundCache.shared, isCancelled: { ring.generation != gen }, emit: out)
            : BoostSynthesis.runPieces(ssml: job.ssml, scheme: job.scheme, settings: settings, rules: RuleBook.shared(),
                                       main: voice, other: otherVoice, cache: SoundCache.shared, isCancelled: { ring.generation != gen }, emit: out)
        if status != .ok && status != .cancelled {
            log.error("request failed: \(String(describing: status), privacy: .public) voice \(job.scheme.main.id, privacy: .public)")
        }
        log.debug("request done in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(String(describing: status), privacy: .public), end: \(self.voice.lastEnd, privacy: .public)")
        if DiagnosticLog.isOn { record(job, status: status, started: t0, firstAudio: firstAudio) }
        ring.finish(gen: gen)
    }

    /// One request in the diagnostic log: the scheme and the voices it really got, VoiceOver's rate, what was read (or
    /// only its length), and how long each step took.
    private func record(_ job: Job, status: BoostSynthesis.Status, started t0: Date, firstAudio: Date?) {
        func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
        func voices(_ e: VoiceEntry?) -> String { e.map { "\($0.id) -> \(voice.resolve($0)?.identifier ?? "none")" } ?? "none" }
        let s = job.scheme
        let request = SSML.parse(job.ssml)
        // VoiceOver's own SSML, when what it reads may be recorded: how it marks up a request (bookmarks, languages ...)
        if DiagnosticLog.recordsSpeech { DiagnosticLog.write("request #\(job.gen) ssml: \(job.ssml.prefix(800))") }
        DiagnosticLog.write("request #\(job.gen) for \(job.voice)")
        DiagnosticLog.write("request #\(job.gen) \"\(s.name)\": main \(voices(s.main)), secondary \(voices(s.secondary)); VoiceOver rate \(Int((request.rate * 100).rounded()))%, boost \(s.boost), numbers \(s.numbers.rawValue), rules \(s.useRules ? "on" : "off"); \(DiagnosticLog.speech(request.segments.map(\.text).joined(separator: " ")))")
        let cache = SoundCache.shared.counts
        let how = (plainText ? "plain text" : "SSML pieces") + ", a synthesizer per voice, sound cache \(cache.hits) hits / \(cache.misses) misses so far"
        DiagnosticLog.write("request #\(job.gen) \(status): waited \(ms(job.submitted, t0)) ms to start, first audio after \(firstAudio.map { "\(ms(t0, $0)) ms" } ?? "none"), done in \(ms(t0, Date())) ms, \(how)")
    }
}

public class BoostAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    /// Before iOS 27 VoiceOver works another way (logs from iOS 26.7 phones and an iPad): it sends each part of an item as
    /// a request of its own, after a cancel, and went on to no second part with this extension ("点赞" without its count,
    /// "可按住 转文字" without "文本栏", no hint), while Apple's voices and eSpeak-NG-style providers read them all: the
    /// system synthesizer announced every utterance to VoiceOver, which then dropped the rest (`AnnouncementGuard`).
    /// There a pull with nothing to play and nothing coming also says "complete" with no frames, as eSpeak-NG's provider
    /// does (`AudioRing.completeWhenIdle`), and a pull waits a little for a late block rather than leave a gap (the host
    /// may pull ahead of real time).
    static let beforeIOS27 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27

    private var outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!
    private let ring = AudioRing()
    private let worker = SynthWorker()
    /// Set by the app's `sendLog` command: the next read of the state carries the diagnostic log.
    private var sendLog = false

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SystemVoice.sampleRate), channels: 1, interleaved: false)!
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        ring.completeWhenIdle = BoostAudioUnit.beforeIOS27
        if BoostAudioUnit.beforeIOS27 && !ProcessInfo.processInfo.isiOSAppOnMac { _ = AnnouncementGuard.install() }
        // maximumFramesToRender is left to the host (a limit of its own can make render calls fail while music plays).
        // The synthesizer is not touched here: the system also creates this unit just to list voices.
        worker.start()
        traced("init") {}
    }

    deinit {
        traced("deinit") { worker.stop() }
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    /// The user's voice schemes (the app's `schemes.json`; the default schemes before the app first ran).
    private var schemes: [VoiceScheme] { VoiceScheme.shared() }

    /// Only the schemes, each in its main voice's language list (`offeredLanguages`: a Chinese one in every Chinese list,
    /// as a voice per list), not also in its secondary voice's (a Chinese scheme reads English through its secondary
    /// voice all the same).
    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            traced("speechVoices") {
                schemes.flatMap { s in
                    s.offeredLanguages.map {
                        AVSpeechSynthesisProviderVoice(name: s.name, identifier: s.providerIdentifier(for: $0),
                                                       primaryLanguages: [$0], supportedLanguages: [$0])
                    }
                }
            }
        }
        set {}
    }

    /// The voices this extension can use, for the app (`UsableVoices`): an out-of-process audio unit's state is the one
    /// thing it can hand over.
    public override var fullState: [String: Any]? {
        get {
            traced("fullState get") {
                var s = super.fullState ?? [:]
                s[UsableVoices.stateKey] = AVSpeechSynthesisVoice.speechVoices()
                    .filter { VoiceEntry.isWrappable($0.identifier) }
                    .map { ["id": $0.identifier, "name": $0.name, "lang": $0.language] }
                if sendLog {
                    sendLog = false
                    s[DiagnosticLog.logKey] = DiagnosticLog.contents()
                }
                return s
            }
        }
        set {
            traced("fullState set") {
                // the app's commands about the diagnostic log (see `DiagnosticLog`)
                switch newValue?[DiagnosticLog.commandKey] as? String {
                case "sendLog": sendLog = true
                case "clearLog": DiagnosticLog.clear()
                #if DEBUG
                case "cpuBench": CPUBench.run()
                case "rateBench": CPUBench.rates()
                case "mixBench": CPUBench.mixed()
                case "cacheBench": CPUBench.cached()
                case "placeBench": CPUBench.placement()
                #endif
                default: super.fullState = newValue
                }
            }
        }
    }

    public override func allocateRenderResources() throws {
        try traced("allocateRenderResources") { try allocate() }
    }

    public override func deallocateRenderResources() {
        traced("deallocateRenderResources") { super.deallocateRenderResources() }
    }

    private func allocate() throws {
        try super.allocateRenderResources()
        #if DEBUG
        // which system voices this process can see (the app may see more)
        let seen = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("yue") || $0.language.hasPrefix("en") }
        log.notice("VOASSIST-VOICES \(seen.count) zh/en voices: \(seen.map { "\($0.identifier)[\($0.quality.rawValue)]" }.joined(separator: " "), privacy: .public)")
        #endif
        // a guess at the scheme VoiceOver uses (the first one) and its secondary voice; the worker loads the right ones
        // after the first request in any case
        guard let first = schemes.first else { return }
        worker.warm(first.main, secondary: first.secondary)
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let ring = self.ring
        let legacy = BoostAudioUnit.beforeIOS27
        return { actionFlags, _, frameCount, _, outputData, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            var delivered = frames
            for i in 0..<abl.count {
                guard let dst = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if i == 0 {
                    // possibly a real-time thread: no real waiting (the synthesis runs ~150x faster than real time and the
                    // first audio is awaited in synthesizeSpeechRequest), only a few ms of slack for a late block
                    // (before iOS 27 more of it: a host pulling ahead of real time had better get a late block than a gap)
                    let (n, finished) = ring.read(into: dst, count: frames, timeout: legacy ? 0.02 : 0.003)
                    #if LATENCY_PROBE
                    if let line = LatencyTrace.sound(dst, n) {
                        DispatchQueue.global().async { log.notice("LATENCY-TRACE frames \(frames) | \(line, privacy: .public)") }
                    }
                    #endif
                    if n < frames { (dst + n).update(repeating: 0, count: frames - n) }
                    if finished {
                        actionFlags.pointee = .offlineUnitRenderAction_Complete
                        delivered = n // the last block reports the frames it really holds (none when idle)
                    }
                } else {
                    dst.update(repeating: 0, count: frames)
                }
                abl[i].mDataByteSize = UInt32(delivered * MemoryLayout<Float>.size)
            }
            return noErr
        }
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        traced("synthesizeSpeechRequest") { synthesize(speechRequest) }
    }

    private func synthesize(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        #if LATENCY_PROBE
        LatencyTrace.begin(Thread.isMainThread ? "request(main)" : "request(bg)")
        #endif
        let gen = ring.reset(producing: true) // also tells a still-running previous utterance to stop
        recordPreviousPlayback()
        worker.submit(SynthWorker.Job(ssml: speechRequest.ssmlRepresentation, scheme: scheme(for: speechRequest.voice), gen: gen, ring: ring,
                                      voice: "\(speechRequest.voice.identifier) \(speechRequest.voice.primaryLanguages)/\(speechRequest.voice.supportedLanguages)"))
        // Return once the first audio exists: the host starts pulling when this returns, and every block pulled before
        // that would be silence in front of the speech. The synthesizer reports on the main queue, so when the system
        // calls us on the main thread, its run loop has to keep turning while we wait.
        // Start with a little audio in hand (or the whole of a shorter utterance), so that the first blocks do not run dry
        // while the speed-up is still catching up; more during a voice switch (AudioRing).
        // Not longer: the host's calls come one after another, so while this waits, its cancel and the next request
        // wait too. (Builds 21-26 waited for the whole request before iOS 27: an iPad with iPadOS 26.7 got a long item
        // after 520 ms instead of 24, and swiping on meanwhile waited for all of it; it never ran dry without the wait.)
        let deadline = Date(timeIntervalSinceNow: 0.8)
        if Thread.isMainThread {
            while !ring.ready(gen: gen) && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        } else {
            ring.waitForAudio(gen: gen, timeout: deadline.timeIntervalSinceNow)
        }
        #if LATENCY_PROBE
        LatencyTrace.mark("ready")
        #endif
    }

    /// The scheme behind the voice VoiceOver asked for. A scheme deleted meanwhile is read by another one of its language
    /// (or the plain default), so VoiceOver never goes silent.
    private func scheme(for voice: AVSpeechSynthesisProviderVoice) -> VoiceScheme {
        let list = schemes
        if let id = VoiceScheme.schemeID(fromProvider: voice.identifier), let s = list.first(where: { $0.id == id }) { return s }
        let lang = voice.primaryLanguages.first ?? "zh-CN"
        if let s = list.first(where: { $0.language == lang }) { return s }
        return VoiceScheme.defaults.first { $0.language == lang }
            ?? VoiceScheme(name: voice.name, main: VoiceEntry(id: "", name: voice.name, lang: lang), secondary: nil)
    }

    public override func cancelSpeechRequest() {
        traced("cancelSpeechRequest") {
            ring.reset()
            recordPreviousPlayback()
        }
    }

    /// How the host played the request before (over once the next one comes, or it is cancelled), for the diagnostic log.
    private func recordPreviousPlayback() {
        guard DiagnosticLog.isOn, let p = ring.previousPlayback(), p.gen > 0, p.pulls > 0 || p.samples > 0 else { return }
        DiagnosticLog.write("playback #\(p.gen): first pull after \(p.firstPullAfterMs.map { "\($0) ms" } ?? "never"), \(p.pulls) pulls of \(p.minFrames)-\(p.maxFrames) frames (\(p.pullsBeforeAudio) before any audio), first audio out after \(p.startedAfterMs.map { "\($0) ms" } ?? "never"), ran dry \(p.ranDry) times (\(p.dryMs) ms), \(p.samples) samples, \(p.complete ? "complete" : "not complete")")
    }
}

/// Entry point named in the extension's Info.plist (NSExtensionPrincipalClass).
@objc(BoostAudioUnitFactory)
public class BoostAudioUnitFactory: NSObject, AUAudioUnitFactory {
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try BoostAudioUnit(componentDescription: componentDescription, options: [])
    }

    // AUAudioUnitFactory inherits NSExtensionRequestHandling; there is nothing to do per request.
    public func beginRequest(with context: NSExtensionContext) {}
}
