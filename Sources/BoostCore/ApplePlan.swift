import Foundation

/// One request as the system voice reads it: VoiceOver's own SSML, handed to the system voice, so that its pauses
/// (`<break>`, sentences, paragraphs, punctuation) come out exactly as when VoiceOver reads that voice itself: the
/// system voice shortens them with the speaking rate (a 500 ms break lasts 459 ms at the normal rate, 108 ms at the
/// fastest; measured), which silence of our own did not.
///
/// What changes on the way: the rate (VoiceOver's speed, capped at what the system voice can do, see `VoiceOverRate`), the
/// text (reading rules; the other language wrapped in `<voice name="…">`, which the system voice switches to by itself),
/// and language/voice tags of VoiceOver's are dropped (the scheme decides the voices).
public struct ApplePlan: Equatable {
    /// For `AVSpeechUtterance(ssmlRepresentation:)`.
    public var ssml: String
    /// The voices in the order the system voice reads them. It ends every stretch of one voice with an empty buffer
    /// (breaks and sentences do not), so the n-th stretch of audio belongs to `segments[n]`.
    public var segments: [RunVoice]
    /// Pause kept where segment i ends and i+1 begins (the system voice leaves its whole end-of-utterance silence there,
    /// ~190 ms at the normal rate): nil = keep it (the text before ends in punctuation), else the pause in ms:
    /// `ApplePlanner.switchPauseMs` at the main voice's speed (see `Trimmer.endStretch`).
    public var switchCapMs: [Int?]
    /// The request starts / ends with a `<break>`: that silence is VoiceOver's and must not be trimmed.
    public var keepLeading: Bool
    public var keepTrailing: Bool
    /// Anything to say at all (else it is a spacer of breaks only).
    public var hasText: Bool
    /// The speed (x normal) the main voice reads at.
    public var speed: Double
}

public enum ApplePlanner {
    /// The pause where the voices switch without punctuation between them, in ms at the normal speed (shorter as the
    /// voice speaks faster, like the voice's own pauses), on top of the voices' own soft ends, which stay. 0 by ear:
    /// build 3's ~30 ms felt like a break; none with the soft ends cut away (build 4) very odd. Not a user
    /// setting; `render-samples --switch-pause` tries others.
    public static var switchPauseMs = 0

    /// `ssml` is VoiceOver's request (or our own for a preview).
    public static func plan(_ ssml: String, scheme: VoiceScheme, rules: RuleBook, map: RateMap) -> ApplePlan {
        let ns = ssml as NSString
        let re = try! NSRegularExpression(pattern: "<[^>]*>|[^<]+")
        var out = ""
        var runs: [(voice: RunVoice, text: String, pauseBefore: Bool)] = []
        // a <break>, or a sentence or paragraph boundary, since the last text: VoiceOver's pause, to be kept even where the
        // voice switches there ("App Store", 800 ms, "轻点两下以打开"; "Safari" / "按钮")
        var pauseAhead = false
        var spaceAhead = false
        var rateStack: [Double] = [] // speed (x normal) of the open <prosody> elements
        var speed: Double?
        var meaningful: [Bool] = [] // per kept token: true for a <break>, false for text (to find leading/trailing breaks)
        let secondaryID = scheme.secondary?.id
        var sawSpeak = false

        func currentSpeed() -> Double { rateStack.last ?? 1 }

        for m in re.matches(in: ssml, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if tok.hasPrefix("<?") || tok.hasPrefix("<!") { continue } // declarations, comments
            if tok.hasPrefix("<") {
                let lower = tok.lowercased()
                let name = lower.dropFirst(lower.hasPrefix("</") ? 2 : 1).prefix { $0.isLetter || $0 == "-" || $0 == ":" }
                switch name {
                case "lang", "voice", "audio":
                    continue // the scheme decides the voices
                case "speak":
                    if !lower.hasPrefix("</") { sawSpeak = true }
                    out += withoutLang(tok)
                case "prosody":
                    if lower.hasPrefix("</") {
                        if !rateStack.isEmpty { rateStack.removeLast() }
                        out += tok
                    } else {
                        var t = withoutLang(tok)
                        var s = currentSpeed()
                        if let r = SSML.attribute("rate", in: tok) {
                            s = min(SSML.rate(r), map.maxMultiplier)
                            if speed == nil { speed = s }
                            t = replacing(attribute: "rate", in: t, with: percent(s))
                        }
                        if !tok.hasSuffix("/>") { rateStack.append(s) }
                        out += t
                    }
                case "break":
                    meaningful.append(true)
                    pauseAhead = true
                    out += tok
                case "s", "p":
                    pauseAhead = true
                    out += withoutLang(tok)
                default:
                    out += withoutLang(tok)
                }
                continue
            }
            // text: rules and numbers, then the other language's stretches to the secondary voice
            let text = decode(tok)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // white space between two inline elements still parts their words ("<prosody>Hello</prosody>
                // <prosody>world</prosody>"); a single space, written only if more text follows
                if !text.isEmpty && !runs.isEmpty { spaceAhead = true }
                continue
            }
            if spaceAhead { out += " "; spaceAhead = false }
            let t = scheme.prepared(text, rules: rules)
            guard !t.isEmpty else { continue }
            meaningful.append(false)
            let pieces = secondaryID == nil ? [LanguageRun(t, .main)] : LanguageRuns.split(t, mainLanguage: scheme.main.lang)
            for p in pieces where !p.text.isEmpty {
                // a capital letter the split left on its own ("C 语言"): read as the letter, not "capital C" / "大写C"
                // (a request that is nothing but the letter, VoiceOver moving by character, stays as it is)
                let text = pieces.count > 1 ? LanguageRuns.lowercasingLoneCapital(p.text) : p.text
                runs.append((p.voice, text, pauseAhead && !runs.isEmpty))
                pauseAhead = false
                if p.voice == .other, let id = secondaryID {
                    let rel = scheme.secondaryRate
                    if abs(rel - 1) > 0.001 {
                        // nested rates are absolute for the system voice (measured): the main speed times the relative one
                        let s = min(currentSpeed() * rel, map.maxMultiplier)
                        out += "<voice name=\"\(id)\"><prosody rate=\"\(percent(s))\">\(encode(text))</prosody></voice>"
                    } else {
                        out += "<voice name=\"\(id)\">\(encode(text))</voice>"
                    }
                } else {
                    out += encode(text)
                }
            }
        }
        if !sawSpeak { out = "<speak>\(out)</speak>" }

        // the stretches as the system voice splits them: consecutive runs of one voice are one
        var segs: [(voice: RunVoice, text: String, pauseBefore: Bool)] = []
        for r in runs {
            if let last = segs.last, last.voice == r.voice { segs[segs.count - 1].text += r.text } else { segs.append(r) }
        }
        let mainSpeed = speed ?? 1
        let pause = Int((Double(switchPauseMs) / max(mainSpeed, 0.1)).rounded())
        let caps: [Int?] = segs.indices.dropLast().map { i in
            // VoiceOver's own pause (a break, a new sentence) where the voices switch: kept as the system voice makes it
            if segs[i + 1].pauseBefore { return nil }
            let seg = segs[i].text
            // a stretch that is only a symbol read out (the dot of "Node.js") is no full stop
            guard seg.contains(where: { $0.isLetter || $0.isNumber }) else { return pause }
            let end = seg.trimmingCharacters(in: .whitespaces).last
            return end.map { "，。！？、；：,.!?;:…".contains($0) } == true ? nil : pause
        }
        let hasText = runs.contains { $0.text.contains { $0.isLetter || $0.isNumber } }
        return ApplePlan(ssml: out, segments: segs.map(\.voice), switchCapMs: caps,
                         keepLeading: meaningful.first ?? false, keepTrailing: meaningful.last ?? false,
                         hasText: hasText, speed: mainSpeed)
    }

    /// A minimal SSML of our own from the parsed request (text, breaks, prosody), for when the system voice rejects
    /// VoiceOver's SSML as rewritten.
    public static func rebuild(_ p: SpeechParams) -> String {
        var body = ""
        for seg in p.segments {
            body += encode(seg.text)
            if seg.silenceMs > 0 { body += "<break time=\"\(seg.silenceMs)ms\"/>" }
        }
        return "<speak><prosody rate=\"\(Int((p.rate * 100).rounded()))%\">\(body)</prosody></speak>"
    }

    static func percent(_ speed: Double) -> String { "\(Int((speed * 100).rounded()))%" }

    static func withoutLang(_ tag: String) -> String {
        tag.replacingOccurrences(of: "\\s+xml:lang\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "", options: .regularExpression)
    }

    static func replacing(attribute name: String, in tag: String, with value: String) -> String {
        tag.replacingOccurrences(of: "\\b\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "\(name)=\"\(value)\"", options: .regularExpression)
    }

    static func decode(_ s: String) -> String { SSML.decodeEntities(s) }

    static func encode(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension VoiceOverRate {
    /// The SSML a preview sends for VoiceOver's rate slider at `percent`, as VoiceOver itself would.
    public static func previewSSML(_ text: String, percent: Double) -> String {
        "<speak><prosody rate=\"\(Int((speed(percent: percent) * 100).rounded()))%\">\(ApplePlanner.encode(text))</prosody></speak>"
    }
}
