import CSonic

/// Speed-up without changing pitch, the way NVDA's "rate boost" does it: Bill Cox's Sonic library itself (C, unmodified,
/// at the commit NVDA pins; Sources/CSonic), mono 16-bit samples, default quality. Sonic is built for speeding speech up
/// by large factors for blind listeners: pitch-synchronous overlap-add, PICOLA below 2x, smooth up to 6x and beyond.
public final class Sonic {
    private let stream: OpaquePointer
    private var shorts: [Int16] = []

    /// `speed` > 1 speeds up (3 = three times as fast).
    public init(speed: Float, sampleRate: Int) {
        stream = sonicCreateStream(Int32(sampleRate), 1)
        sonicSetSpeed(stream, speed)
    }

    deinit {
        sonicDestroyStream(stream)
    }

    /// Feeds PCM and returns the output that became ready.
    public func push(_ pcm: [Float]) -> [Float] {
        guard !pcm.isEmpty else { return [] }
        shorts = pcm.map { Int16(max(-1, min(1, $0)) * 32767) }
        _ = shorts.withUnsafeMutableBufferPointer { sonicWriteShortToStream(stream, $0.baseAddress, Int32($0.count)) }
        return read()
    }

    /// Ends the stream: everything still buffered comes out.
    public func flush() -> [Float] {
        _ = sonicFlushStream(stream)
        return read()
    }

    private func read() -> [Float] {
        let n = Int(sonicSamplesAvailable(stream))
        guard n > 0 else { return [] }
        var out = [Int16](repeating: 0, count: n)
        let got = out.withUnsafeMutableBufferPointer { Int(sonicReadShortFromStream(stream, $0.baseAddress, Int32(n))) }
        return out.prefix(max(got, 0)).map { Float($0) / 32768 }
    }
}
