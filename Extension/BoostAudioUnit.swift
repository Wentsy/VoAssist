import AVFoundation
import AudioToolbox
import os

private let log = Logger(subsystem: "com.zdyi.voassist", category: "voice")

/// One persistent synthesis thread. `AVSpeechSynthesizer.write` reports on the main queue, so the waiting happens here,
/// never on the main thread. Only the newest request matters.
final class SynthWorker {
    struct Job {
        let ssml: String
        let scheme: VoiceScheme
        let gen: Int
        let ring: AudioRing
    }

    private let cond = NSCondition()
    private var pending: Job?
    private var warmEntries: [VoiceEntry] = []
    private var warmed = Set<String>() // voices this process has already loaded (worker thread only)
    private var stopping = false
    private let voice = SystemVoice()

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
    }

    /// Loads these voices in the background (a voice's first utterance is ~250 ms slower).
    func warm(_ entries: [VoiceEntry]) {
        cond.lock(); warmEntries = entries; cond.signal(); cond.unlock()
    }

    private func loop() {
        while true {
            cond.lock()
            while pending == nil && warmEntries.isEmpty && !stopping { cond.wait() }
            if stopping { cond.unlock(); break }
            let job = pending
            pending = nil
            // one voice at a time, so a request never waits for more than one warm-up
            let warm = job == nil ? warmEntries.removeFirst() : nil
            cond.unlock()
            if let job = job {
                run(job)
                warmed.insert(job.scheme.main.id)
                // VoiceOver may use any of our schemes: once one is in use, load its secondary voice while idle
                if let other = job.scheme.secondary, !warmed.contains(other.id) {
                    cond.lock(); warmEntries.append(other); cond.unlock()
                }
            } else if let w = warm, !warmed.contains(w.id) {
                voice.warmUp(w)
                warmed.insert(w.id)
            }
        }
    }

    private func run(_ job: Job) {
        let ring = job.ring, gen = job.gen
        guard ring.generation == gen else { return } // superseded before it started
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
        let settings = BoostSettings.load()
        #if LATENCY_PROBE
        LatencyTrace.mark("settings")
        #endif
        let status = BoostSynthesis.run(ssml: job.ssml, scheme: job.scheme, settings: settings, rules: RuleBook.shared(),
                                        voice: voice, isCancelled: { ring.generation != gen },
                                        switching: { ring.setSwitching($0, gen: gen) }) { pcm in
            #if LATENCY_PROBE
            if !pcm.isEmpty { LatencyTrace.mark("first output") }
            #endif
            ring.append(pcm, gen: gen)
        }
        if status != .ok && status != .cancelled {
            log.error("request failed: \(String(describing: status), privacy: .public) voice \(job.scheme.main.id, privacy: .public)")
        }
        log.debug("request done in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(String(describing: status), privacy: .public), end: \(self.voice.lastEnd, privacy: .public), voice switches took \(self.voice.lastSwitchWaitsMs.map(String.init).joined(separator: "/"), privacy: .public) ms")
        ring.finish(gen: gen)
    }
}

public class BoostAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    private var outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!
    private let ring = AudioRing()
    private let worker = SynthWorker()

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SystemVoice.sampleRate), channels: 1, interleaved: false)!
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        // maximumFramesToRender is left to the host (a limit of its own can make render calls fail while music plays).
        // The synthesizer is not touched here: the system also creates this unit just to list voices.
        worker.start()
    }

    deinit {
        worker.stop()
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    /// The user's voice schemes (the app's `schemes.json`; the default schemes before the app first ran).
    private var schemes: [VoiceScheme] { VoiceScheme.shared() }

    /// Only the schemes, each in its main voice's language alone: a Chinese scheme in the Mandarin list, not also in the
    /// English one (it reads English through its secondary voice all the same).
    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            schemes.map {
                AVSpeechSynthesisProviderVoice(name: $0.name, identifier: $0.providerIdentifier,
                                               primaryLanguages: [$0.language], supportedLanguages: [$0.language])
            }
        }
        set {}
    }

    /// The voices this extension can use, for the app (`UsableVoices`): an out-of-process audio unit's state is the one
    /// thing it can hand over.
    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            s[UsableVoices.stateKey] = AVSpeechSynthesisVoice.speechVoices()
                .filter { VoiceEntry.isWrappable($0.identifier) }
                .map { ["id": $0.identifier, "name": $0.name, "lang": $0.language] }
            return s
        }
        set { super.fullState = newValue }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        #if DEBUG
        // which system voices this process can see (the app may see more)
        let seen = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("yue") || $0.language.hasPrefix("en") }
        log.notice("VOASSIST-VOICES \(seen.count) zh/en voices: \(seen.map { "\($0.identifier)[\($0.quality.rawValue)]" }.joined(separator: " "), privacy: .public)")
        #endif
        // a guess at the scheme VoiceOver uses (the first one) and its secondary voice; the worker loads the right ones
        // after the first request in any case
        guard let first = schemes.first else { return }
        worker.warm([first.main] + (first.secondary.map { [$0] } ?? []))
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let ring = self.ring
        return { actionFlags, _, frameCount, _, outputData, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            var delivered = frames
            for i in 0..<abl.count {
                guard let dst = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if i == 0 {
                    // possibly a real-time thread: no real waiting (the synthesis runs ~150x faster than real time and the
                    // first audio is awaited in synthesizeSpeechRequest), only a few ms of slack for a late block
                    let (n, finished) = ring.read(into: dst, count: frames, timeout: 0.003)
                    #if LATENCY_PROBE
                    if let line = LatencyTrace.sound(dst, n) {
                        DispatchQueue.global().async { log.notice("LATENCY-TRACE frames \(frames) | \(line, privacy: .public)") }
                    }
                    #endif
                    if n < frames { (dst + n).update(repeating: 0, count: frames - n) }
                    if finished {
                        actionFlags.pointee = .offlineUnitRenderAction_Complete
                        delivered = n // the last block reports the frames it really holds
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
        #if LATENCY_PROBE
        LatencyTrace.begin(Thread.isMainThread ? "request(main)" : "request(bg)")
        #endif
        let gen = ring.reset() // also tells a still-running previous utterance to stop
        worker.submit(SynthWorker.Job(ssml: speechRequest.ssmlRepresentation, scheme: scheme(for: speechRequest.voice), gen: gen, ring: ring))
        // Return once the first audio exists: the host starts pulling when this returns, and every block pulled before
        // that would be silence in front of the speech. The synthesizer reports on the main queue, so when the system
        // calls us on the main thread, its run loop has to keep turning while we wait.
        // Start with a little audio in hand (or the whole of a shorter utterance), so that the first blocks do not run dry
        // while the speed-up is still catching up; more during a voice switch (AudioRing).
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
        ring.reset()
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
