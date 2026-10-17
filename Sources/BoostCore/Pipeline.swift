import Foundation

/// One utterance of a system voice on its way to the listener: trim silence -> speed up (Sonic) -> gain.
///
/// Only Sonic, at any factor: its author measured WSOLA (which this used beyond 3x) distorting speech past ~2.5x to the
/// point that fast listeners cannot follow, while Sonic stays smooth to 6x and more.
public final class SegmentProcessor {
    private let trimmer: Trimmer?
    private let sonic: Sonic?
    private let gain: Float

    /// `trimEdges` drops leading/trailing silence; inner pauses are kept as the voice made them (nil `innerGapMs`).
    public init(sampleRate: Int, stretch: Double, trimLeading: Bool, trimTrailing: Bool, innerGapMs: Int? = nil,
                gain: Float = 1) {
        trimmer = Trimmer(sampleRate: sampleRate, innerGapMs: innerGapMs, trimLeading: trimLeading, trimTrailing: trimTrailing)
        sonic = stretch > 1.01 ? Sonic(speed: Float(stretch), sampleRate: sampleRate) : nil
        self.gain = gain
    }

    /// The old interface (whole-utterance trimming with capped inner pauses), for the tools.
    public convenience init(sampleRate: Int, stretch: Double, trimSilence: Bool, gain: Float) {
        self.init(sampleRate: sampleRate, stretch: stretch, trimLeading: trimSilence, trimTrailing: trimSilence,
                  innerGapMs: trimSilence ? 250 : nil, gain: gain)
    }

    public func push(_ pcm: [Float]) -> [Float] {
        let t = trimmer?.push(pcm) ?? pcm
        return applyingGain(sonic?.push(t) ?? t)
    }

    /// One voice's stretch ended and another's follows: everything of it, with the pause cut down to `capMs` (nil = as
    /// the voice made it), comes out now, Sonic flushed, so that the end of the word plays while the system voice is
    /// still switching voices (see `Trimmer.endStretch`).
    public func endStretch(capMs: Int?) -> [Float] {
        let t = trimmer?.endStretch(capMs: capMs) ?? []
        guard let s = sonic else { return applyingGain(t) }
        return applyingGain(s.push(t) + s.flush())
    }

    public func finish() -> [Float] {
        let t = trimmer?.finish() ?? []
        guard let s = sonic else { return applyingGain(t) }
        return applyingGain(s.push(t) + s.flush())
    }

    private func applyingGain(_ v: [Float]) -> [Float] {
        guard gain != 1 else { return v }
        var o = v
        applyGain(&o, gain)
        return o
    }
}

/// How fast the system voices speak for an `AVSpeechUtterance.rate` (0...1): the speech length at rate 0.5 divided by the
/// length at that rate. Used for a secondary voice's relative speed (VoiceOver's own rate maps to `rate` directly, see
/// `VoiceOverRate`). Measured on macOS 27 with Tingting (zh-CN) and Samantha (en-US), whose curves were identical;
/// above 0.9 the synthesizer barely gets faster (0.9 and 0.95 gave the same length). The app re-measures it on the phone
/// (`RateMap.calibrate`) and stores the result in the shared settings.
public struct RateMap: Codable, Equatable {
    /// (rate, speed multiplier), increasing in both.
    public var points: [[Double]]

    public static let measured = RateMap(points: [
        [0.0, 0.556], [0.1, 0.667], [0.2, 0.715], [0.3, 0.834], [0.4, 0.909], [0.5, 1.0],
        [0.52, 1.078], [0.54, 1.235], [0.56, 1.357], [0.58, 1.427], [0.6, 1.592], [0.65, 1.830],
        [0.7, 2.110], [0.75, 2.490], [0.8, 2.809], [0.85, 3.127], [0.9, 3.524], [1.0, 4.044],
    ])

    public init(points: [[Double]]) {
        // keep only strictly increasing pairs (a plateau or a measuring glitch would make the inverse ambiguous)
        var clean: [[Double]] = []
        for p in points where p.count == 2 {
            if let l = clean.last, p[0] <= l[0] || p[1] <= l[1] { continue }
            clean.append(p)
        }
        self.points = clean.count >= 2 ? clean : [[0.5, 1.0], [1.0, 4.0]]
    }

    enum CodingKeys: String, CodingKey { case points }

    /// Through `init(points:)`: a map from the file is cleaned like a measured one (no point, one point or a broken pair
    /// would crash every request).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try c.decode([[Double]].self, forKey: .points))
    }

    /// The fastest the synthesizer itself goes.
    public var maxMultiplier: Double { points.last![1] }

    /// The speed multiplier at `rate` (linear between the measured points).
    public func multiplier(at rate: Double) -> Double {
        if rate <= points.first![0] { return points.first![1] }
        for i in 1..<points.count where rate <= points[i][0] {
            let (r0, m0, r1, m1) = (points[i - 1][0], points[i - 1][1], points[i][0], points[i][1])
            return m0 + (m1 - m0) * (rate - r0) / (r1 - r0)
        }
        return maxMultiplier
    }

    /// The `AVSpeechUtterance.rate` that gives `multiplier` (clamped to what the synthesizer can do).
    public func rate(for multiplier: Double) -> Float {
        if multiplier <= points.first![1] { return Float(points.first![0]) }
        for i in 1..<points.count where multiplier <= points[i][1] {
            let (r0, m0) = (points[i - 1][0], points[i - 1][1])
            let (r1, m1) = (points[i][0], points[i][1])
            return Float(r0 + (r1 - r0) * (multiplier - m0) / (m1 - m0))
        }
        return Float(points.last![0])
    }
}

/// VoiceOver's speaking rate. The `rate` of its SSML is the speed itself (x normal), measured on an iPhone Air (iOS 27)
/// from what it sent at each step of its slider: 50 % "100%", every 5 % more another 30 %, 100 % "400%". The system
/// voices read SSML in the same scale ("X%" is X/100 of the normal speed, up to about 4x), so it is passed on as it is.
/// VoiceOver reading an Apple voice itself comes within 5 % of these speeds, with a few uneven steps of its own (90 % and
/// 95 % alike, 40 % and 45 % alike) that are not copied. (Builds up to 7 read it as relative to the default rate 0.5 and
/// put it through the steep `AVSpeechUtterance.rate` curve: 55 % came out 1.8x, 70 % and up all 4x.)
public enum VoiceOverRate {
    /// The speed (x normal) VoiceOver asks for at its rate slider `percent`, for the app's preview: as measured from 50 %
    /// up; below, assumed to fall evenly to half the speed at 0 % (not captured yet).
    public static func speed(percent p: Double) -> Double {
        p >= 50 ? 1 + (p - 50) * 0.06 : 0.5 + p / 100
    }
}

/// Brings a voice's samples to another loudness without clipping: above 0.9 the peaks are bent softly towards 1.
public func applyGain(_ v: inout [Float], _ gain: Float) {
    guard gain != 1 else { return }
    for i in v.indices {
        let y = v[i] * gain
        let a = abs(y)
        v[i] = a <= 0.9 ? y : (y < 0 ? -1 : 1) * (0.9 + 0.1 * tanhf((a - 0.9) / 0.1))
    }
}
