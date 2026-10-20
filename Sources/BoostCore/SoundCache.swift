import Foundation

/// The sound of short texts the system voices have read, to play again instead of reading them again.
///
/// Before iOS 27 every utterance costs the system voice 50-70 ms of processor time spread over many cores before it
/// sounds (iPad, iPadOS 26.7: inside `TTSMauiSpeechEngine`'s `_speakString`, whatever the length; on iOS 27 ~6 ms), and
/// VoiceOver sends a name, its "按钮" and its hint as separate requests, which a bilingual scheme splits further by
/// language. Short texts come again and again (traits, hints, names in a list read over and over), so their sound is kept
/// for the voice and the way they were read: the same samples, without the cost (iOS 27 too, where the cost is mostly
/// the sound made).
///
/// Only utterances read to their end are kept. Holds at most `maxSamples` (16-bit), the least recently used go first.
public final class SoundCache {
    public static let shared = SoundCache()

    /// Longer texts seldom come again and would push out the short ones.
    static let maxCharacters = 24
    /// ~45 s of sound at `SystemVoice.sampleRate`, 2 MB.
    static let maxSamples = 1_000_000

    /// A sound as the voice delivered it: the samples, and where each block it came in ended.
    private struct Sound {
        var samples: [Int16]
        var ends: [Int]
    }

    private let lock = NSLock()
    private var sounds: [String: Sound] = [:]
    private var order: [String] = [] // least recently used first
    private var held = 0
    private var hits = 0
    private var misses = 0

    public init() {}

    /// How many lookups found a sound, and how many did not.
    public var counts: (hits: Int, misses: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, misses)
    }

    /// The key for `text` read by `voice` (an identifier) the way `reading` says (the rate and pitch of a plain
    /// utterance, or the SSML it is read from); nil if it is too long to keep.
    public static func key(_ text: String, voice: String, reading: String) -> String? {
        text.count <= maxCharacters ? "\(voice)|\(reading)|\(text)" : nil
    }

    /// Hands the sound kept for `key` to `take` in the blocks the voice delivered it in: the speed-up turns them into the
    /// very samples it made of the voice's own (Sonic's output depends a little on how its input is cut), and the first
    /// sound goes out before the rest is sped up. False if there is none (or no key).
    public func play(_ key: String?, _ take: ([Float]) -> Void) -> Bool {
        guard let key else { return false }
        lock.lock()
        guard let s = sounds[key] else {
            misses += 1
            lock.unlock()
            return false
        }
        hits += 1
        touch(key)
        lock.unlock()
        var start = 0
        for end in s.ends {
            take(s.samples[start..<end].map { Float($0) / 32768 })
            start = end
        }
        return true
    }

    /// Keeps the whole sound of an utterance, the blocks as they came.
    public func keep(_ key: String, _ blocks: [[Float]]) {
        let count = blocks.reduce(0) { $0 + $1.count }
        guard count > 0, count <= SoundCache.maxSamples / 8 else { return }
        var s = Sound(samples: [], ends: [])
        s.samples.reserveCapacity(count)
        for b in blocks {
            // the voices deliver 16-bit samples, converted as x / 32768: back to the same integers
            s.samples += b.map { Int16(max(min(($0 * 32768).rounded(), 32767), -32768)) }
            s.ends.append(s.samples.count)
        }
        lock.lock(); defer { lock.unlock() }
        if let old = sounds.updateValue(s, forKey: key) {
            held -= old.samples.count
            touch(key)
        } else {
            order.append(key)
        }
        held += count
        while held > SoundCache.maxSamples, !order.isEmpty {
            let k = order.removeFirst()
            held -= sounds.removeValue(forKey: k)?.samples.count ?? 0
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        sounds.removeAll()
        order.removeAll()
        held = 0
        hits = 0
        misses = 0
    }

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}
