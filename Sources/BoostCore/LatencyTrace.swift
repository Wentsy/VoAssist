import Foundation

#if LATENCY_PROBE
/// Measuring only: built when `SWIFT_ACTIVE_COMPILATION_CONDITIONS=LATENCY_PROBE` is passed to xcodebuild, never in a
/// release. The times (ms) of the steps of the newest speech request, from its arrival.
public enum LatencyTrace {
    private static let lock = NSLock()
    private static var t0 = CFAbsoluteTimeGetCurrent()
    private static var marks: [(String, Double)] = []

    public static func begin(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        t0 = CFAbsoluteTimeGetCurrent()
        marks = [(label, 0)]
    }

    /// Records `label` once per request.
    public static func mark(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        guard !marks.contains(where: { $0.0 == label }) else { return }
        marks.append((label, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    /// The first time audio with sound in it goes to the host: marks it and returns the summary to log, else nil.
    public static func sound(_ p: UnsafePointer<Float>, _ n: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !marks.contains(where: { $0.0 == "sound" }), n > 0,
              UnsafeBufferPointer(start: p, count: n).contains(where: { abs($0) > 0.001 }) else { return nil }
        marks.append(("sound", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        return marks.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: " | ")
    }
}
#endif
