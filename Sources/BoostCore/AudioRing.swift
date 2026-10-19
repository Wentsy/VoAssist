import Foundation

/// Thread-safe FIFO of Float32 samples between the synthesis thread (producer) and the render block (consumer).
///
/// The player starts as soon as it has one whole block of what the host pulls at a time in hand: once the system voice's
/// first audio is out, the rest follows at many times real time, so waiting for more only delays the speech after
/// VoiceOver's sound (50 ms, as in NVDA's rate boost, cost 6 to 10 ms on an iPhone Air; 20 ms was better), while less
/// than a block would play the first block part sound, part silence. Until the host has pulled, a block is taken to be
/// `defaultBlock` frames. While the system voice is switching voices it waits for enough to last through that (300 ms)
/// or for the next voice to have got going (`BoostSynthesis.run`): 100 ms was tried and "Safari浏览器" started at once,
/// ran dry after "Safari" while Tingting's sound trickled in, and the cut popped. Should it run dry in the middle all the
/// same, it does not get the rest in scraps between silences: it fades out, waits as at the start, and fades back in
/// (6 ms each way: 2 ms popped).
public final class AudioRing {
    public static let defaultBlock = 256
    public static let switchSamples = SystemVoice.sampleRate * 300 / 1000
    private static let fade = SystemVoice.sampleRate * 6 / 1000

    private let cond = NSCondition()
    private var samples: [Float] = []
    private var head = 0
    private var done = false
    private var gen = 0
    private var playing = false // false: waiting for audio in hand before playing on (at the start, after running dry)
    private var ranDry = false
    private var begun = false // the host has started playing this request (or has been told it is complete)
    private var switching = false
    private var block = AudioRing.defaultBlock // the frames the host pulls at a time, as last seen
    private var playback = Playback(gen: 0)
    private var resetAt = DispatchTime.now().uptimeNanoseconds
    private var dryAt: UInt64? // when playback last ran dry, until it plays on

    /// How the host played one request, for the diagnostic log.
    public struct Playback: Equatable {
        public var gen: Int
        /// Render calls, and the frames they asked for (fewest, most).
        public var pulls = 0
        /// From the request to the host's first render call, and the calls before the first audio was handed over.
        public var firstPullAfterMs: Int?
        public var pullsBeforeAudio = 0
        public var minFrames = 0
        public var maxFrames = 0
        /// From the request to the first audio handed to the host (nil: none was).
        public var startedAfterMs: Int?
        /// Times playback ran dry in the middle, and how long it went without sound then, in all.
        public var ranDry = 0
        public var dryMs = 0
        public var samples = 0
        /// The host was told the request is complete.
        public var complete = false
    }

    /// Say "complete" (with no frames) on every pull while there is nothing to play and nothing is coming: before a
    /// request, after its end, after a cancel, as eSpeak-NG's provider does (a pull answered with silence says "still
    /// speaking"). Set before iOS 27 while chasing VoiceOver's dropped parts there, which had another cause
    /// (`AnnouncementGuard`); kept, as VoiceOver reads well with it. Only for hosts that pull after the request has
    /// returned (VoiceOver does; the app's probes wait first, `waitAsVoiceOverDoes`).
    public var completeWhenIdle = false
    private var producing = false // a request is under way: its audio is still to come

    public init() {}

    /// The request before the current one, as the host played it.
    public func previousPlayback() -> Playback? {
        cond.lock(); defer { cond.unlock() }
        return lastPlayback
    }
    private var lastPlayback: Playback?

    /// Enough in hand to start or go on (under the lock).
    private var canPlay: Bool {
        done || samples.count - head >= (switching ? AudioRing.switchSamples : block)
    }

    public var generation: Int {
        cond.lock(); defer { cond.unlock() }
        return gen
    }

    /// Starts a new utterance: drops pending audio and returns its generation number.
    /// `producing`: a new request begins (its audio follows), else the current one is dropped.
    @discardableResult
    public func reset(producing p: Bool = false) -> Int {
        cond.lock(); defer { cond.unlock() }
        gen += 1
        producing = p
        lastPlayback = playback
        playback = Playback(gen: gen)
        resetAt = DispatchTime.now().uptimeNanoseconds
        samples.removeAll(keepingCapacity: true)
        head = 0
        done = false
        playing = false
        ranDry = false
        begun = false
        switching = false
        dryAt = nil
        cond.broadcast()
        return gen
    }

    public func append(_ pcm: [Float], gen g: Int) {
        guard !pcm.isEmpty else { return }
        cond.lock(); defer { cond.unlock() }
        guard g == gen else { return }
        samples.append(contentsOf: pcm)
        playback.samples += pcm.count
        cond.broadcast()
    }

    public func finish(gen g: Int) {
        cond.lock(); defer { cond.unlock() }
        if g == gen {
            done = true
            producing = false
            cond.broadcast()
        }
    }

    /// The system voice is switching voices (true) or the next voice has sounded (false).
    public func setSwitching(_ on: Bool, gen g: Int) {
        cond.lock(); defer { cond.unlock() }
        if g == gen { switching = on; cond.broadcast() }
    }

    /// True once the player could start (or has started already: a short request can be played to its end before the
    /// waiting side looks again), or a newer request replaced generation `g`.
    public func ready(gen g: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return gen != g || begun || canPlay
    }

    /// Waits (at most `timeout` seconds) until `ready`. Not on the main thread: the synthesis needs it.
    public func waitForAudio(gen g: Int, timeout: TimeInterval) {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while gen == g && !begun && !canPlay {
            if !cond.wait(until: deadline) { break }
        }
    }

    /// Copies up to `count` samples, waiting (at most `timeout` seconds) for a full block. The second value is true once
    /// the producer has finished and everything was read.
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int, timeout: TimeInterval) -> (Int, Bool) {
        cond.lock(); defer { cond.unlock() }
        block = max(count, 1)
        playback.pulls += 1
        if playback.firstPullAfterMs == nil {
            playback.firstPullAfterMs = Int((DispatchTime.now().uptimeNanoseconds - resetAt) / 1_000_000)
        }
        playback.minFrames = playback.pulls == 1 ? count : min(playback.minFrames, count)
        playback.maxFrames = max(playback.maxFrames, count)
        if completeWhenIdle && !producing && samples.count - head == 0 {
            if begun { playback.complete = true }
            done = false
            return (0, true)
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while samples.count - head < count && !done {
            if !cond.wait(until: deadline) { break }
        }
        if !playing {
            if !canPlay {
                if !begun { playback.pullsBeforeAudio += 1 }
                return (0, false)
            }
            playing = true
            begun = true
            if let d = dryAt {
                playback.dryMs += Int((DispatchTime.now().uptimeNanoseconds - d) / 1_000_000)
                dryAt = nil
            }
            if playback.startedAfterMs == nil {
                playback.startedAfterMs = Int((DispatchTime.now().uptimeNanoseconds - resetAt) / 1_000_000)
            }
            cond.broadcast()
        }
        let n = min(samples.count - head, count)
        if n > 0 {
            samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress! + head, count: n) }
            head += n
        }
        if ranDry {
            ranDry = false
            let k = min(n, AudioRing.fade)
            for i in 0..<k { dst[i] *= Float(i) / Float(k) }
        }
        if n < count && !done {
            // ran dry mid-request: no sound cut off with a click, and none in scraps until there is enough again
            let k = min(n, AudioRing.fade)
            for i in 0..<k { dst[n - k + i] *= 1 - Float(i + 1) / Float(k) }
            playing = false
            ranDry = true
            playback.ranDry += 1
            dryAt = DispatchTime.now().uptimeNanoseconds
        }
        if head == samples.count && head > 0 {
            samples.removeAll(keepingCapacity: true)
            head = 0
        }
        let finished = done && head == samples.count
        // "Complete" is reported once per request. The speech request arrives over XPC and the render calls over another
        // channel, so the host's first pull for the NEXT request can come before `reset()`: it must get silence, not a
        // second "complete" of the old request (which ended the new one at once, without a sound).
        if finished {
            done = false
            playback.complete = true
        }
        return (n, finished)
    }
}
