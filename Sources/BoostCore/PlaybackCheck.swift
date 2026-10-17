import Foundation

/// How audio produced over time would play in real time with the extension's player (`AudioRing`): it starts with
/// `startMs` in hand, holds out for `switchMs` while the system voice is switching voices, and after running dry waits
/// in the same way. Tells whether synthesis keeps ahead of the listener, notably where voices switch.
public struct PlaybackCheck {
    public let sampleRate: Int
    let start: Int
    let switchLead: Int
    private let t0 = Date()
    private var produced = 0
    private var switching = false
    private var done = false
    private var playing = false
    private var runFrom: TimeInterval = 0 // when the current run of playing began
    private var posAtRun = 0              // samples played before it
    private var dryAt: TimeInterval?
    /// From the request until the player started (ms).
    public private(set) var startDelayMs: Int?
    /// Each time the player ran dry in the middle: where in the audio (ms from its start) and for how long (ms).
    public private(set) var stalls: [(atMs: Int, ms: Int)] = []

    /// `startMs`: one block of the host's (AudioRing starts with one whole block in hand; 256 frames is ~12 ms).
    public init(sampleRate: Int = SystemVoice.sampleRate, startMs: Int = 12, switchMs: Int = 300) {
        self.sampleRate = sampleRate
        start = sampleRate * startMs / 1000
        switchLead = sampleRate * switchMs / 1000
    }

    public mutating func add(_ count: Int) { event { $0.produced += count } }
    public mutating func setSwitching(_ on: Bool) { event { $0.switching = on } }
    public mutating func finish() { event { $0.done = true } }

    private mutating func event(_ change: (inout PlaybackCheck) -> Void) {
        let now = Date().timeIntervalSince(t0)
        if playing {
            let pos = posAtRun + Int((now - runFrom) * Double(sampleRate))
            if pos >= produced {
                playing = false
                dryAt = runFrom + Double(produced - posAtRun) / Double(sampleRate)
                posAtRun = produced
            }
        }
        change(&self)
        guard !playing else { return }
        let inHand = produced - posAtRun
        if inHand > 0 && (done || inHand >= (switching ? switchLead : start)) {
            if let d = dryAt {
                stalls.append((posAtRun * 1000 / sampleRate, Int(((now - d) * 1000).rounded())))
            } else {
                startDelayMs = Int((now * 1000).rounded())
            }
            playing = true
            runFrom = now
            dryAt = nil
        }
    }

    /// For people: when it starts, and "无断续" or the dry spells.
    public var summary: String {
        let s = "开始前等 \(startDelayMs ?? -1) ms，"
        return s + (stalls.isEmpty ? "无断续" : "断了 \(stalls.count) 次（" + stalls.map { "第 \($0.atMs) ms 处 \($0.ms) ms" }.joined(separator: "、") + "）")
    }
}
