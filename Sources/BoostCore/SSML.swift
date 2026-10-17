import Foundation

/// A stretch of text followed by real silence. VoiceOver puts SSML `<break>` between pieces of one announcement
/// (a control's name, its state, its hint ...); `explicitBreak` is true for every silence that came from a `<break>`.
public struct Segment: Equatable {
    public var text: String
    public var silenceMs: Int
    public var explicitBreak = false

    public init(text: String, silenceMs: Int, explicitBreak: Bool = false) {
        self.text = text
        self.silenceMs = silenceMs
        self.explicitBreak = explicitBreak
    }
}

/// What the system asked for.
public struct SpeechParams: Equatable {
    public var segments: [Segment] = []
    /// Speed multiplier, 1 = normal.
    public var rate = 1.0
    /// `AVSpeechUtterance.pitchMultiplier` (0.5...2).
    public var pitch: Float = 1
    /// 0...1
    public var volume: Float = 1

    public init() {}
}

/// The SSML VoiceOver / Speak Screen send to a speech-synthesis provider (as VoiceOver really sends it, from device
/// logs: `<prosody rate pitch volume>`, `<break>`, `<s>`, `<p>`).
public enum SSML {
    public static func parse(_ ssml: String) -> SpeechParams {
        var p = SpeechParams()
        if let r = attribute("rate", in: ssml) { p.rate = rate(r) }
        if let v = attribute("pitch", in: ssml) { p.pitch = pitch(v) }
        if let v = attribute("volume", in: ssml) { p.volume = volume(v) }
        p.segments = segments(from: ssml)
        return p
    }

    /// Splits at the pauses of the SSML: `<break>` (the time or strength it names), and the end of a sentence (`</s>`) or
    /// paragraph (`</p>`) when more text follows. The text before each one comes with the silence after it. A sentence or
    /// paragraph end right next to a `<break>` adds nothing: the `<break>` already says how long to wait.
    public static func segments(from ssml: String) -> [Segment] {
        let ns = ssml as NSString
        guard let re = try? NSRegularExpression(pattern: "<break\\b([^>]*?)/?\\s*>|</(?:s|p)\\s*>", options: [.caseInsensitive]) else {
            return [Segment(text: clean(ssml), silenceMs: 0)]
        }
        var result: [Segment] = []
        var last = 0
        for m in re.matches(in: ssml, range: NSRange(location: 0, length: ns.length)) {
            let chunk = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tag = ns.substring(with: m.range).lowercased()
            if tag.hasPrefix("<break") {
                let attrs = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
                result.append(Segment(text: clean(chunk), silenceMs: breakMs(attrs), explicitBreak: true))
            } else {
                let rest = ns.substring(from: m.range.location + m.range.length)
                let breakFollows = rest.range(of: "^(?:\\s|<(?!break)[^>]*>)*<break", options: [.regularExpression, .caseInsensitive]) != nil
                let afterBreak = clean(chunk).isEmpty && (result.last?.silenceMs ?? 0) > 0
                if breakFollows || afterBreak { continue }
                result.append(Segment(text: clean(chunk), silenceMs: tag.hasPrefix("</p") ? 400 : 150))
            }
            last = m.range.location + m.range.length
        }
        let tail = clean(ns.substring(from: last))
        if !tail.isEmpty {
            result.append(Segment(text: tail, silenceMs: 0))
        } else if let l = result.last, !l.explicitBreak {
            result[result.count - 1].silenceMs = 0 // no pause after the very last sentence
        }
        // pieces without text only carry their pause: fold them into the piece before
        var merged: [Segment] = []
        for s in result {
            if s.text.isEmpty, var l = merged.last, !l.text.isEmpty {
                l.silenceMs += s.silenceMs
                l.explicitBreak = l.explicitBreak || s.explicitBreak
                merged[merged.count - 1] = l
            } else {
                merged.append(s)
            }
        }
        return merged.isEmpty ? [Segment(text: clean(ssml), silenceMs: 0)] : merged
    }

    /// Strips tags, decodes entities, collapses white space.
    static func clean(_ s: String) -> String {
        var t = decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let entity = try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|lt|gt|quot|apos|amp);")

    /// XML entities decoded, each once (so "&amp;lt;" is "&lt;"): the five named ones and numeric references
    /// ("&#8217;", "&#x26;").
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for m in entity.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: t), let g = Range(m.range(at: 1), in: t) else { continue }
            let name = t[g]
            let value: String?
            switch name {
            case "lt": value = "<"
            case "gt": value = ">"
            case "quot": value = "\""
            case "apos": value = "'"
            case "amp": value = "&"
            default:
                let digits = name.dropFirst()
                let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                value = code.flatMap { $0 == 0 ? nil : Unicode.Scalar($0) }.map { String(Character($0)) } // no NUL in the SSML
            }
            if let v = value { t.replaceSubrange(r, with: v) }
        }
        return t
    }

    /// Milliseconds of silence for a `<break>`'s attributes (`time="300ms"`, `time="1s"`, `strength="medium"`), capped at 2 s.
    static func breakMs(_ attrs: String) -> Int {
        func cap(_ ms: Double) -> Int { ms.isNaN ? 0 : Int(max(0, min(ms, 2000))) }
        if let time = attribute("time", in: attrs)?.lowercased().trimmingCharacters(in: .whitespaces) {
            if time.hasSuffix("ms"), let n = Double(time.dropLast(2)) { return cap(n) }
            if time.hasSuffix("s"), let n = Double(time.dropLast(1)) { return cap(n * 1000) }
            if let n = Double(time) { return cap(n) }
        }
        switch attribute("strength", in: attrs)?.lowercased() {
        case "none": return 0
        case "x-weak": return 100
        case "weak": return 200
        case "medium": return 350
        case "strong": return 500
        case "x-strong": return 800
        default: return 300
        }
    }

    static func attribute(_ name: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// A number with optional sign/percent/`x` suffix as a relative multiplier; nil if it is not numeric.
    static func multiplier(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let pct = t.hasSuffix("%")
        if pct { t.removeLast() }
        if t.hasSuffix("x") { t.removeLast() }
        guard let v = Double(t.replacingOccurrences(of: "+", with: "")), v.isFinite else { return nil }
        if pct {
            // "+20%" / "-20%" are relative changes, "120%" is a ratio.
            return (s.contains("+") || s.contains("-")) ? 1 + v / 100 : v / 100
        }
        return v
    }

    static func rate(_ s: String) -> Double {
        switch s.lowercased() {
        case "x-slow": return 0.5
        case "slow": return 0.75
        case "medium", "default": return 1.0
        case "fast": return 1.5
        case "x-fast": return 2.0
        default: return min(max(multiplier(s) ?? 1.0, 0.3), 8.0)
        }
    }

    static func pitch(_ s: String) -> Float {
        let v = s.lowercased().trimmingCharacters(in: .whitespaces)
        let m: Double
        switch v {
        case "x-low": m = 0.6
        case "low": m = 0.8
        case "medium", "default": m = 1.0
        case "high": m = 1.2
        case "x-high": m = 1.4
        default:
            if v.hasSuffix("st"), let n = Double(v.dropLast(2).replacingOccurrences(of: "+", with: "")) {
                m = pow(2.0, n / 12.0) // semitones
            } else if v.hasSuffix("hz") {
                m = 1.0 // hertz needs the voice's base pitch
            } else {
                m = multiplier(v) ?? 1.0
            }
        }
        return Float(min(max(m, 0.5), 2.0))
    }

    static func volume(_ s: String) -> Float {
        switch s.lowercased() {
        case "silent": return 0
        case "x-soft": return 0.25
        case "soft": return 0.5
        case "medium", "default", "loud", "x-loud": return 1 // "medium" is the unchanged volume, not a reduced one
        default:
            // relative change in decibels ("-6dB", "+3dB"): 0 dB is full, -6 dB about half
            let t = s.lowercased().trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("db"), let db = Double(t.dropLast(2).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) {
                return Float(min(max(pow(10.0, min(db, 0) / 20.0), 0), 1))
            }
            guard let v = multiplier(s) else { return 1 }
            if s.hasSuffix("%") { return Float(min(max(v, 0), 1)) }
            return Float(v <= 1.0 ? max(v, 0) : min(v / 100, 1))
        }
    }
}
