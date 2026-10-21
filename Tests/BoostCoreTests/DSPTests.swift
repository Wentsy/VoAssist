import XCTest
@testable import BoostCore

private let sr = 22050

private func sine(_ hz: Float, _ secs: Float, amp: Float = 0.3) -> [Float] {
    (0..<Int(Float(sr) * secs)).map { amp * sin(2 * .pi * hz * Float($0) / Float(sr)) }
}

private func zeroCrossingHz(_ v: ArraySlice<Float>) -> Double {
    var n = 0
    var prev = v.first ?? 0
    for x in v.dropFirst() {
        if (prev < 0) != (x < 0) { n += 1 }
        prev = x
    }
    return Double(n) / 2 / (Double(v.count) / Double(sr))
}

private func stream(_ push: ([Float]) -> [Float], _ flush: () -> [Float], _ x: [Float], chunk: Int) -> [Float] {
    var out: [Float] = []
    var i = 0
    while i < x.count {
        out += push(Array(x[i..<min(i + chunk, x.count)]))
        i += chunk
    }
    return out + flush()
}

final class SonicTests: XCTestCase {
    func testLengthFollowsSpeedAndPitchIsKept() {
        let x = sine(180, 2)
        for speed: Float in [1.25, 1.5, 2, 2.5, 3] {
            let s = Sonic(speed: speed, sampleRate: sr)
            let y = stream(s.push, s.flush, x, chunk: 1000)
            let want = Double(x.count) / Double(speed)
            XCTAssertEqual(Double(y.count), want, accuracy: want * 0.03, "speed \(speed)")
            XCTAssertEqual(zeroCrossingHz(y[1000..<(y.count - 1000)]), 180, accuracy: 6, "speed \(speed)")
        }
    }

    func testChunkingHardlyChangesOutput() {
        // Sonic's PICOLA bookkeeping depends a little on how the input arrives; the result must stay the same sound
        let x = sine(150, 1)
        func once(_ chunk: Int) -> [Float] { let s = Sonic(speed: 2.5, sampleRate: sr); return stream(s.push, s.flush, x, chunk: chunk) }
        let whole = once(x.count)
        for c in [333, 1] {
            let y = once(c)
            XCTAssertEqual(Double(y.count), Double(whole.count), accuracy: Double(whole.count) * 0.02, "chunk \(c)")
            XCTAssertEqual(zeroCrossingHz(y[500..<(y.count - 500)]), 150, accuracy: 5, "chunk \(c)")
        }
    }

    func testShortInput() {
        let s = Sonic(speed: 2, sampleRate: sr)
        XCTAssertTrue(s.push([0.1, 0.2, 0.3]).isEmpty, "too little to find a pitch period yet")
        XCTAssertLessThanOrEqual(s.flush().count, 4)
    }
}

final class SonicHighSpeedTests: XCTestCase {
    func testSonicAloneUpToSix() {
        let x = sine(160, 6)
        for f: Float in [1.5, 3, 4.5, 6] {
            let s = Sonic(speed: f, sampleRate: sr)
            let y = stream(s.push, s.flush, x, chunk: 1024)
            let want = Double(x.count) / Double(f)
            XCTAssertEqual(Double(y.count), want, accuracy: want * 0.04, "f \(f)")
            XCTAssertEqual(zeroCrossingHz(y[1000..<(y.count - 1000)]), 160, accuracy: 6, "f \(f): pitch kept")
        }
    }
}

final class TrimmerTests: XCTestCase {
    private let block = sr * 4 / 1000

    func testTrimsLeadingAndTrailingSilence() {
        var x = [Float](repeating: 0, count: block * 20)
        let tone = sine(300, 0.3)
        x += tone
        x += [Float](repeating: 0, count: sr / 2)
        let t = Trimmer(sampleRate: sr)
        let y = stream(t.push, t.finish, x, chunk: 777)
        let lead = sr * 10 / 1000
        // lead-in + the tone (its last partial block counts as sound) and no trailing pad
        XCTAssertEqual(Double(y.count), Double(lead + tone.count), accuracy: Double(block))
        XCTAssertEqual(y.first, 0)
        XCTAssertLessThan(abs(y.last!), 0.01)
    }

    func testKeepsInnerPausesWhenAsked() {
        var x = sine(300, 0.2)
        x += [Float](repeating: 0, count: sr)
        x += sine(300, 0.2)
        let t = Trimmer(sampleRate: sr, innerGapMs: nil)
        let y = stream(t.push, t.finish, x, chunk: 512)
        XCTAssertEqual(Double(y.count), Double(2 * Int(Double(sr) * 0.2) + sr), accuracy: Double(2 * block))
    }

    /// A pause kept whole is the voice's own waveform: no fade around it (only a pause cut short gets those).
    func testWholePauseIsNotFaded() {
        let x = sine(300, 0.1) + [Float](repeating: 0, count: sr / 50) + sine(300, 0.1)
        let t = Trimmer(sampleRate: sr, innerGapMs: nil, trimLeading: false, trimTrailing: false)
        let y = stream(t.push, t.finish, x, chunk: 300)
        XCTAssertEqual(y.count, x.count)
        let second = x.count - Int(Float(sr) * 0.1)
        XCTAssertEqual(Array(y[(second + 5)..<(second + 60)]), Array(x[(second + 5)..<(second + 60)]))
    }

    func testEdgesKeptWhenNotTrimmed() {
        var x = [Float](repeating: 0, count: sr / 10)
        x += sine(300, 0.2)
        x += [Float](repeating: 0, count: sr / 10)
        let t = Trimmer(sampleRate: sr, innerGapMs: nil, trimLeading: false, trimTrailing: false)
        let y = stream(t.push, t.finish, x, chunk: 300)
        XCTAssertEqual(y.count, x.count)
    }

    func testCapsInnerPause() {
        var x = sine(300, 0.2)
        x += [Float](repeating: 0, count: sr) // one second inside the utterance
        x += sine(300, 0.2)
        let t = Trimmer(sampleRate: sr)
        let y = stream(t.push, t.finish, x, chunk: 512)
        let inner = sr * 250 / 1000
        XCTAssertEqual(Double(y.count), Double(2 * Int(Double(sr) * 0.2) + inner), accuracy: Double(2 * block))
    }

    func testChunkingDoesNotChangeOutput() {
        var x = [Float](repeating: 0, count: 300)
        x += sine(250, 0.1)
        x += [Float](repeating: 0, count: 3000)
        x += sine(250, 0.07)
        x += [Float](repeating: 0, count: 900)
        func once(_ c: Int) -> [Float] { let t = Trimmer(sampleRate: sr); return stream(t.push, t.finish, x, chunk: c) }
        XCTAssertEqual(once(1), once(4096))
        XCTAssertEqual(once(7), once(88))
    }

    func testAllSilenceGivesNothing() {
        let t = Trimmer(sampleRate: sr)
        XCTAssertTrue(t.push([Float](repeating: 0, count: 10_000)).isEmpty)
        XCTAssertTrue(t.finish().isEmpty)
    }

    /// "Safari浏览器": the end of "Safari" must come out when its stretch ends, not when the next voice first sounds.
    func testStretchEndReleasesEverything() {
        let tone = sine(300, 0.3)
        let t = Trimmer(sampleRate: sr, innerGapMs: nil)
        var y = t.push(tone + [Float](repeating: 0, count: sr / 5))
        y += t.endStretch(capMs: 20)
        XCTAssertEqual(Double(y.count), Double(tone.count + sr * 20 / 1000), accuracy: Double(block))
        // nil = the whole pause, as the voice made it
        let t2 = Trimmer(sampleRate: sr, innerGapMs: nil)
        let y2 = t2.push(tone + [Float](repeating: 0, count: sr / 5)) + t2.endStretch(capMs: nil)
        XCTAssertEqual(Double(y2.count), Double(tone.count + sr / 5), accuracy: Double(block))
        // the next voice's own leading silence is dropped bar a short faded lead-in, and the end trims as usual
        let lead = sr * 4 / 1000
        var z = t.push([Float](repeating: 0, count: sr / 10) + tone + [Float](repeating: 0, count: sr / 5))
        z += t.finish()
        XCTAssertEqual(Double(z.count), Double(lead + tone.count), accuracy: Double(block))
    }

    /// "打开Safari": the soft end of "开" stays whole, then exactly the pause asked for, then the next voice with only a
    /// short lead-in (cutting the soft ends away, with no pause, sounded very odd).
    func testVoiceSwitchKeepsNaturalEndsAndExactPause() {
        let soft = [Float](repeating: 0.005, count: sr * 40 / 1000) // a fading syllable end, over the silence threshold
        let tone = sine(300, 0.3)
        let t = Trimmer(sampleRate: sr, innerGapMs: nil)
        var y = t.push(tone + soft + [Float](repeating: 0, count: sr / 10))
        y += t.endStretch(capMs: 30)
        XCTAssertEqual(Double(y.count), Double(tone.count + soft.count + sr * 30 / 1000), accuracy: Double(block))
        // a pause longer than the voice's own silence is padded
        let t2 = Trimmer(sampleRate: sr, innerGapMs: nil)
        let y2 = t2.push(tone + [Float](repeating: 0, count: sr / 100)) + t2.endStretch(capMs: 50)
        XCTAssertEqual(Double(y2.count), Double(tone.count + sr * 50 / 1000), accuracy: Double(block))
        let z = t.push([Float](repeating: 0, count: sr / 20) + soft + tone)
        XCTAssertEqual(Double(z.count), Double(sr * 4 / 1000 + soft.count + tone.count - sr * 8 / 1000), accuracy: Double(block))
    }
}

final class StretchSwitchTests: XCTestCase {
    /// With Sonic in the chain too: everything of the first stretch, sped up, is out before the second one starts.
    func testSonicFlushedAtStretchEnd() {
        let tone = sine(200, 0.4)
        let p = SegmentProcessor(sampleRate: sr, stretch: 2, trimLeading: true, trimTrailing: true)
        var y: [Float] = []
        var i = 0
        while i < tone.count {
            y += p.push(Array(tone[i..<min(i + 512, tone.count)]))
            i += 512
        }
        y += p.push([Float](repeating: 0, count: sr / 5))
        y += p.endStretch(capMs: 20)
        let expected = Double(tone.count + sr * 20 / 1000) / 2
        XCTAssertEqual(Double(y.count), expected, accuracy: Double(sr) * 0.01)
        // the second stretch follows on normally
        let z = p.push(tone) + p.finish()
        XCTAssertEqual(Double(z.count), Double(tone.count) / 2, accuracy: Double(sr) * 0.01)
    }
}

final class PlanTests: XCTestCase {
    func testRateMapInverse() {
        let m = RateMap.measured
        XCTAssertEqual(m.rate(for: 1), 0.5, accuracy: 1e-6)
        XCTAssertEqual(m.rate(for: 4.044), 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.rate(for: 10), 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.rate(for: 0.1), 0.0, accuracy: 1e-6)
        let r = m.rate(for: 2.3)
        XCTAssertTrue(r > 0.7 && r < 0.75, "\(r)")
    }

    func testBrokenMapFromAFileFallsBack() throws {
        let m = try JSONDecoder().decode(RateMap.self, from: Data(#"{"points":[[0.5]]}"#.utf8))
        XCTAssertEqual(m.points.count, 2)
        XCTAssertEqual(m.maxMultiplier, 4)
    }

    func testPlateausAreDropped() {
        let m = RateMap(points: [[0.5, 1], [0.9, 3.5], [0.95, 3.5], [1.0, 4]])
        XCTAssertEqual(m.points.count, 3)
    }

    func testVoiceOverRateIsTheSpeed() {
        // what VoiceOver sent on an iPhone Air: 50 % "100%", 55 % "130%", 100 % "400%"
        XCTAssertEqual(VoiceOverRate.speed(percent: 50), 1.0, accuracy: 1e-9)
        XCTAssertEqual(VoiceOverRate.speed(percent: 55), 1.3, accuracy: 1e-9)
        XCTAssertEqual(VoiceOverRate.speed(percent: 100), 4.0, accuracy: 1e-9)
        XCTAssertEqual(SSML.rate("129.99994%"), 1.3, accuracy: 1e-4)
    }

    func testGainSoftLimits() {
        var v: [Float] = [0.1, -0.2, 0.5, -0.8]
        applyGain(&v, 2)
        XCTAssertEqual(v[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(v[1], -0.4, accuracy: 1e-6)
        XCTAssertTrue(v[2] > 0.9 && v[2] < 1, "\(v[2])")
        XCTAssertTrue(v[3] < -0.9 && v[3] > -1, "\(v[3])")
    }
}

final class AudioRingTests: XCTestCase {
    private let ms = sr / 1000

    private func pull(_ r: AudioRing, _ n: Int) -> ([Float], Bool) {
        var b = [Float](repeating: 0, count: n)
        let (got, done) = b.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, count: n, timeout: 0) }
        return (Array(b[..<got]), done)
    }

    func testStartsWithALittleInHand() {
        let r = AudioRing()
        let g = r.reset()
        r.append([Float](repeating: 0.5, count: AudioRing.defaultBlock - 1), gen: g)
        XCTAssertFalse(r.ready(gen: g)) // less than one block of the host's
        r.append([Float](repeating: 0.5, count: 1), gen: g)
        XCTAssertTrue(r.ready(gen: g))
        // the host pulls bigger blocks: one of those is wanted, so the first block is never part silence
        XCTAssertEqual(pull(r, 512).0.count, 0)
        r.append([Float](repeating: 0.5, count: 256), gen: g)
        XCTAssertEqual(pull(r, 512).0.count, 512)
    }

    /// Run dry in the middle: faded out, then nothing in scraps until there is enough again, faded back in.
    func testRunningDryFadesAndWaits() {
        let r = AudioRing()
        let g = r.reset()
        r.append([Float](repeating: 0.5, count: 700), gen: g)
        XCTAssertEqual(pull(r, 512).0.count, 512)
        let (a, _) = pull(r, 512) // only 188 left
        XCTAssertEqual(a.count, 188)
        XCTAssertEqual(a.last!, 0, accuracy: 0.01)
        XCTAssertEqual(a[0], 0.5)
        r.append([Float](repeating: 0.5, count: 300), gen: g)
        XCTAssertEqual(pull(r, 512).0.count, 0) // less than a block: no scraps
        r.append([Float](repeating: 0.5, count: 300), gen: g)
        let (b, _) = pull(r, 512)
        XCTAssertEqual(b.count, 512)
        XCTAssertEqual(b[0], 0)
        XCTAssertEqual(b[511], 0.5)
    }

    /// Pacing (`BoostSynthesis.paceBelow`): no wait with little in hand; a wait while more is, which a new request ends
    /// at once.
    func testWaitUntilLow() {
        let r = AudioRing()
        let g = r.reset()
        r.append([Float](repeating: 0.5, count: 100 * ms), gen: g)
        XCTAssertFalse(r.waitUntilLow(gen: g, 0.25))
        r.append([Float](repeating: 0.5, count: 900 * ms), gen: g) // a second in hand, nothing playing
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { r.reset() }
        let t0 = Date()
        XCTAssertTrue(r.waitUntilLow(gen: g, 0.25))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.09)
    }

    /// The end of a request is reported once: the host's first pull for the next one must not get it again.
    func testCompleteOnce() {
        let r = AudioRing()
        let g = r.reset()
        r.append([Float](repeating: 0.5, count: 10 * ms), gen: g)
        r.finish(gen: g)
        XCTAssertTrue(r.ready(gen: g)) // a short request plays without 50 ms in hand
        let (a, done) = pull(r, 512)
        XCTAssertEqual(a.count, 10 * ms)
        XCTAssertTrue(done)
        let (b, again) = pull(r, 512)
        XCTAssertEqual(b.count, 0)
        XCTAssertFalse(again)
        XCTAssertTrue(r.ready(gen: g), "played to its end before the request looked: no waiting out the deadline")
        XCTAssertFalse(r.ready(gen: r.reset()))
    }

    func testPlaybackIsRecordedPerRequest() {
        let ring = AudioRing()
        let g = ring.reset()
        ring.append([Float](repeating: 0.5, count: 600), gen: g)
        ring.finish(gen: g)
        var buf = [Float](repeating: 0, count: 512)
        var complete = false
        while !complete { complete = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 512, timeout: 0).1 } }
        ring.reset()
        let p = ring.previousPlayback()
        XCTAssertEqual(p?.gen, g)
        XCTAssertEqual(p?.pulls, 2)
        XCTAssertEqual(p?.minFrames, 512)
        XCTAssertEqual(p?.samples, 600)
        XCTAssertNotNil(p?.startedAfterMs)
        XCTAssertEqual(p?.complete, true)
        XCTAssertEqual(p?.ranDry, 0)
    }

    /// Before iOS 27, as eSpeak-NG's provider: "complete" with no frames whenever nothing is to play or coming.
    func testCompleteWhenIdle() {
        let ring = AudioRing()
        ring.completeWhenIdle = true
        var buf = [Float](repeating: 1, count: 256)
        func pull() -> (Int, Bool) { buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 256, timeout: 0) } }
        XCTAssertTrue(pull() == (0, true), "before any request")
        let g = ring.reset(producing: true)
        XCTAssertFalse(pull().1, "a request under way is not complete before its audio")
        ring.append([Float](repeating: 0.5, count: 300), gen: g)
        ring.finish(gen: g)
        XCTAssertTrue(pull() == (256, false))
        XCTAssertTrue(pull() == (44, true))
        XCTAssertTrue(pull() == (0, true), "after the end")
        XCTAssertTrue(pull() == (0, true))
        ring.reset()
        XCTAssertTrue(pull() == (0, true), "after a cancel")
        XCTAssertEqual(ring.previousPlayback()?.complete, true)
    }
}

final class SoundCacheTests: XCTestCase {
    private func played(_ cache: SoundCache, _ key: String) -> [[Float]]? {
        var blocks: [[Float]] = []
        return cache.play(key) { blocks.append($0) } ? blocks : nil
    }

    func testPlaysTheSixteenBitSamplesInTheirBlocks() {
        let cache = SoundCache()
        let blocks: [[Float]] = [[0, 1 / 32768], [], [-1, 12345 / 32768, -20000 / 32768]]
        let k = SoundCache.key("按钮", voice: "v", reading: "0.5 1")!
        XCTAssertNil(played(cache, k))
        cache.keep(k, blocks)
        XCTAssertEqual(played(cache, k), blocks)
        XCTAssertEqual(cache.counts.hits, 1)
        XCTAssertEqual(cache.counts.misses, 1)
        XCTAssertFalse(cache.play(nil) { _ in })
    }

    func testKeyTellsVoicesAndReadingsApart() {
        let a = SoundCache.key("Safari", voice: "v", reading: "0.5 1")
        XCTAssertNotEqual(a, SoundCache.key("Safari", voice: "w", reading: "0.5 1"))
        XCTAssertNotEqual(a, SoundCache.key("Safari", voice: "v", reading: "0.6 1"))
        XCTAssertNotEqual(a, SoundCache.key("safari", voice: "v", reading: "0.5 1"))
        XCTAssertNil(SoundCache.key(String(repeating: "长", count: SoundCache.maxCharacters + 1), voice: "v", reading: "0.5 1"))
    }

    func testDropsTheLeastRecentlyUsedFirst() {
        let cache = SoundCache()
        let size = SoundCache.maxSamples / 8
        let pcm = [[Float](repeating: 0.25, count: size)]
        for i in 0..<8 { cache.keep("k\(i)", pcm) }
        XCTAssertNotNil(played(cache, "k0")) // now the most recently used
        cache.keep("k8", pcm)
        XCTAssertNotNil(played(cache, "k0"))
        XCTAssertNil(played(cache, "k1"))
        XCTAssertNotNil(played(cache, "k8"))
        cache.keep("too long", [[Float](repeating: 0, count: size + 1)])
        XCTAssertNil(played(cache, "too long"))
    }
}
