import AVFoundation

/// Markers for the host (`AVSpeechSynthesisProviderAudioUnit.speechSynthesisOutputMetadataBlock`): where in the audio
/// each part of the request's text is. Apple: "the system may delay speech output until it delivers these markers".
/// The system voice's own markers do not survive the trimming and the speed-up, so the parts are placed by their share
/// of the text: a paragraph marker for all of it, then for each stretch of text in the SSML (VoiceOver puts every part
/// of an item in an `<s>` of its own) a sentence marker and a word marker per space-separated word, and a bookmark
/// marker for every `<mark name="…"/>` where it stands (a host may wait for its bookmarks to know how far speech got).
/// Ranges are in the request's SSML (UTF-16), offsets in bytes of the Float32 mono audio handed to the host.
public enum SpeechMarkers {
    public struct Part: Equatable {
        public var mark: AVSpeechSynthesisMarker.Mark
        public var range: NSRange
        public var sample: Int
        /// A bookmark's name.
        public var name: String? = nil
    }

    public static func parts(ssml: String, samples: Int) -> [Part] {
        let ns = ssml as NSString
        let re = try! NSRegularExpression(pattern: "<[^>]*>|[^<]+")
        // the stretches of text and, within each, its words; bookmarks with the stretches they follow
        var stretches: [(range: NSRange, words: [NSRange])] = []
        var bookmarks: [(name: String, range: NSRange, after: Int)] = []
        for m in re.matches(in: ssml, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if tok.hasPrefix("<") {
                if tok.range(of: "^<mark\\b", options: [.regularExpression, .caseInsensitive]) != nil, let name = SSML.attribute("name", in: tok) {
                    bookmarks.append((name, m.range, stretches.count))
                }
                continue
            }
            let words = (tok as NSString).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            var ranges: [NSRange] = []
            var from = m.range.location
            for w in words {
                let r = ns.range(of: w, range: NSRange(location: from, length: NSMaxRange(m.range) - from))
                guard r.location != NSNotFound else { continue }
                ranges.append(r)
                from = NSMaxRange(r)
            }
            guard let first = ranges.first, let last = ranges.last else { continue }
            stretches.append((NSRange(location: first.location, length: NSMaxRange(last) - first.location), ranges))
        }
        let total = stretches.flatMap(\.words).reduce(0) { $0 + $1.length }
        func at(_ chars: Int) -> Int { total > 0 ? samples * chars / total : 0 }
        // characters of text before each stretch
        var before: [Int] = [0]
        for s in stretches { before.append(before.last! + s.words.reduce(0) { $0 + $1.length }) }
        let marks = bookmarks.map { Part(mark: .bookmark, range: $0.range, sample: at(before[$0.after]), name: $0.name) }
        guard let first = stretches.first, let last = stretches.last else { return marks }
        var out = [Part(mark: .paragraph, range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), sample: 0)]
        var done = 0
        for s in stretches {
            out.append(Part(mark: .sentence, range: s.range, sample: at(done)))
            for w in s.words {
                out.append(Part(mark: .word, range: w, sample: at(done)))
                done += w.length
            }
        }
        // in the order of the audio; a bookmark before the text that follows it
        return (out + marks).enumerated().sorted { ($0.element.sample, $0.element.mark == .bookmark ? 0 : 1, $0.offset) < ($1.element.sample, $1.element.mark == .bookmark ? 0 : 1, $1.offset) }.map(\.element)
    }

    public static func markers(ssml: String, samples: Int) -> [AVSpeechSynthesisMarker] {
        markers(parts(ssml: ssml, samples: samples))
    }

    public static func markers(_ parts: [Part]) -> [AVSpeechSynthesisMarker] {
        parts.map { p in
            let bytes = p.sample * MemoryLayout<Float>.size
            if p.mark == .bookmark, let name = p.name, #available(iOS 17.0, macOS 14.0, *) {
                return AVSpeechSynthesisMarker(bookmarkName: name, atByteSampleOffset: bytes)
            }
            return AVSpeechSynthesisMarker(markerType: p.mark, forTextRange: p.range, atByteSampleOffset: bytes)
        }
    }
}
