/// Silence trimming for a synthesizer's PCM stream (mono Float32, any sample rate).
///
/// The system voices start every utterance with a little silence and end it with a long one (about 200 ms at the normal
/// rate): dead air VoiceOver waits through before the next item. Leading silence is dropped (bar a 10 ms lead-in), the
/// trailing silence of an utterance is dropped down to the decay of the last sound, and pauses inside are capped.
///
/// Silence is judged per 4 ms block (a voiced waveform crosses zero all the time, so single samples would cut speech
/// into pieces).
public final class Trimmer {
    /// A block whose samples all stay within this magnitude is silent (speech peaks are ~0.3).
    static let threshold: Float = 48.0 / 32768
    /// Samples at or below this are silence; anything above, in a block under the threshold, is the natural decay of the
    /// last syllable and is kept (up to `decayMax`). The system voices' "silence" is not digital zero but a noise floor of
    /// 2...12 (in 16-bit steps; measured on Tingting and Samantha), so this sits above it.
    static let decayFloor: Float = 20.0 / 32768

    private let block: Int
    private let innerGap: Int // longest pause kept inside a stretch of speech (unlimited when the voice's pauses are wanted)
    private let leadKeep: Int // quiet lead-in kept in front of the first speech block (10 ms)
    private let fadeIn: Int   // the very first sound of an utterance fades in (4 ms): no click from digital silence
    private let fadeOut: Int  // the very end of an utterance fades out (8 ms), also when it ends on speech itself
    private let gapFade: Int  // fade out before / in after a cut-down pause inside an utterance (3 ms)
    private let decayMax: Int // the longest decay kept after the last loud block (60 ms)
    private let switchLead: Int // quiet lead-in kept in front of the next voice after a voice switch (4 ms)
    private let perMs: Double

    private var carry: [Float] = []   // samples not yet forming a whole block
    private var pending: [Float] = [] // quiet samples held back until we know speech follows
    private var started = false
    private var lead: [Float] = []
    private var fresh = true          // nothing has been output for this utterance yet
    private var held: [Float] = []    // the newest fadeOut samples, kept back in case the utterance ends right there
    private var afterSwitch = false   // the next voice of a voice switch has not sounded yet
    private let trimLeading: Bool
    private let trimTrailing: Bool

    /// `innerGapMs` caps the pauses inside an utterance (nil = keep them as the voice made them). `trimLeading` /
    /// `trimTrailing` drop the silence before the first and after the last sound.
    public init(sampleRate: Int, innerGapMs: Int? = 250, trimLeading: Bool = true, trimTrailing: Bool = true) {
        self.trimLeading = trimLeading
        self.trimTrailing = trimTrailing
        started = !trimLeading
        perMs = Double(sampleRate) / 1000
        block = max(sampleRate * 4 / 1000, 1)
        innerGap = innerGapMs.map { sampleRate * $0 / 1000 } ?? Int.max
        leadKeep = sampleRate * 10 / 1000
        fadeIn = sampleRate * 4 / 1000
        fadeOut = sampleRate * 8 / 1000
        gapFade = sampleRate * 3 / 1000
        decayMax = sampleRate * 60 / 1000
        switchLead = sampleRate * 4 / 1000
    }

    /// Feeds PCM, returns what is ready to be played.
    public func push(_ pcm: [Float]) -> [Float] {
        carry.append(contentsOf: pcm)
        let whole = carry.count / block * block
        var out = held
        held.removeAll()
        out.reserveCapacity(out.count + whole)
        var i = 0
        while i < whole {
            consume(carry[i..<i + block], into: &out)
            i += block
        }
        carry.removeFirst(whole)
        fadeInFirst(&out)
        let emit = max(out.count - fadeOut, 0)
        held = Array(out[emit...])
        out.removeLast(out.count - emit)
        return out
    }


    /// One voice's stretch ended and another voice follows: returns the rest of the stretch at once instead of holding it
    /// back until the next voice's first sound (the system voice can take a while to switch voices, and the end of the
    /// word must not wait for that).
    ///
    /// `capMs` nil (VoiceOver puts a break or a new sentence there): the pause stays as the voice made it, the next voice's
    /// leading silence included. Otherwise (no punctuation there, or the pause a punctuation mark asks for, see
    /// `ApplePlanner.switchPause`) it becomes
    /// `capMs`: what the voice made after its last sound (the fading decay, then silence), cut or padded to that. The
    /// sounds themselves keep their natural ends and starts (cutting the soft end of the last syllable away, with no
    /// pause at all, sounded very odd); the next voice's leading silence is dropped (bar a short lead-in).
    public func endStretch(capMs: Int?) -> [Float] {
        var out = held
        held.removeAll()
        if !carry.isEmpty {
            consume(carry[...], into: &out)
            carry.removeAll()
        }
        guard started else { return out }
        if let cap = capMs {
            let n = Int(Double(cap) * perMs)
            var pause = Array(pending.prefix(n))
            if pending.count > n { Trimmer.fadeTail(&pause, gapFade) }
            pause += [Float](repeating: 0, count: n - pause.count)
            out.append(contentsOf: pause)
            started = false
            afterSwitch = true
        } else {
            // the voice's own pause, whole: the next voice's leading silence too (where a <break> between them may be)
            out.append(contentsOf: pending)
        }
        pending.removeAll(keepingCapacity: true)
        lead.removeAll()
        fadeInFirst(&out)
        return out
    }

    /// The utterance ended: returns the last audible samples (with the decay of the last sound, no quiet pad) and resets.
    public func finish() -> [Float] {
        var out = held
        held.removeAll()
        if !carry.isEmpty {
            consume(carry[...], into: &out)
            carry.removeAll()
        }
        if started {
            let decay = min(decayLength(), pending.count)
            out.append(contentsOf: trimTrailing ? pending[..<decay] : pending[...])
            fadeInFirst(&out)
            if trimTrailing { Trimmer.fadeTail(&out, fadeOut) }
        }
        pending.removeAll()
        started = !trimLeading
        fresh = true
        afterSwitch = false
        lead.removeAll()
        return out
    }

    /// Length of the pending quiet stretch that is still decaying sound (not digital silence).
    private func decayLength() -> Int {
        var idx = (pending.count + block - 1) / block - 1 // blocks counted from the start of `pending`
        while idx >= 0 {
            let end = min((idx + 1) * block, pending.count)
            if pending[(idx * block)..<end].contains(where: { abs($0) > Trimmer.decayFloor }) { return min(end, decayMax) }
            idx -= 1
        }
        return 0
    }

    private func fadeInFirst(_ out: inout [Float]) {
        guard fresh, !out.isEmpty else { return }
        fresh = false
        let n = min(out.count, fadeIn)
        for i in 0..<n { out[i] *= Float(i) / Float(n) }
    }

    private func consume(_ b: ArraySlice<Float>, into out: inout [Float]) {
        if b.allSatisfy({ abs($0) <= Trimmer.threshold }) {
            if started {
                pending.append(contentsOf: b)
            } else {
                lead.append(contentsOf: b)
                let keep = afterSwitch ? switchLead : leadKeep
                if lead.count > keep { lead.removeFirst(lead.count - keep) }
            }
            return
        }
        if !started {
            out.append(contentsOf: lead)
            lead.removeAll()
            afterSwitch = false
        }
        // only a pause cut short needs the fades; one kept whole is the voice's own waveform (fading it would soften the
        // burst after a stop's closure, the "b" of 播客)
        let gap = started && pending.count > innerGap
        started = true
        if gap { Trimmer.fadeTail(&out, gapFade) }
        let kept = pending.prefix(innerGap)
        out.append(contentsOf: kept)
        pending.removeAll(keepingCapacity: true)
        let from = out.count
        out.append(contentsOf: b)
        if gap {
            let n = min(gapFade, out.count - from)
            for i in 0..<n { out[from + i] *= Float(i) / Float(gapFade) }
        }
    }

    /// Linear fade to zero over the last `n` samples of `v`.
    static func fadeTail(_ v: inout [Float], _ n: Int) {
        let n = min(n, v.count)
        guard n > 0 else { return }
        let start = v.count - n
        for i in 0..<n { v[start + i] *= 1 - Float(i + 1) / Float(n) }
    }
}
