import AVFoundation

/// Markers for the host (`AVSpeechSynthesisProviderAudioUnit.speechSynthesisOutputMetadataBlock`): where in the audio
/// each part of the request's text is. Apple: "the system may delay speech output until it delivers these markers".
/// The system voice's own markers do not survive the trimming and the speed-up, so the parts are placed by their share
/// of the text: a paragraph marker for all of it, then for each stretch of text in the SSML (VoiceOver puts every part
/// of an item in an `<s>` of its own) a sentence marker and a word marker per space-separated word. Ranges are in the
/// request's SSML (UTF-16), offsets in bytes of the Float32 mono audio handed to the host.
public enum SpeechMarkers {
    public struct Part: Equatable {
        public var mark: AVSpeechSynthesisMarker.Mark
        public var range: NSRange
        public var sample: Int
    }

    public static func parts(ssml: String, samples: Int) -> [Part] {
        let ns = ssml as NSString
        let re = try! NSRegularExpression(pattern: "<[^>]*>|[^<]+")
        // the stretches of text and, within each, its words
        var stretches: [(range: NSRange, words: [NSRange])] = []
        for m in re.matches(in: ssml, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if tok.hasPrefix("<") { continue }
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
        guard let first = stretches.first, let last = stretches.last else { return [] }
        let total = stretches.flatMap(\.words).reduce(0) { $0 + $1.length }
        var out = [Part(mark: .paragraph, range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), sample: 0)]
        var done = 0
        func at(_ chars: Int) -> Int { total > 0 ? samples * chars / total : 0 }
        for s in stretches {
            out.append(Part(mark: .sentence, range: s.range, sample: at(done)))
            for w in s.words {
                out.append(Part(mark: .word, range: w, sample: at(done)))
                done += w.length
            }
        }
        return out
    }

    public static func markers(ssml: String, samples: Int) -> [AVSpeechSynthesisMarker] {
        parts(ssml: ssml, samples: samples).map {
            AVSpeechSynthesisMarker(markerType: $0.mark, forTextRange: $0.range, atByteSampleOffset: $0.sample * MemoryLayout<Float>.size)
        }
    }
}
