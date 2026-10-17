/// Which of a scheme's voices reads a stretch of text.
public enum RunVoice: Equatable {
    /// The main voice.
    case main
    /// The secondary voice: Latin text inside a Chinese main voice's text, Chinese characters inside any other.
    case other
}

public struct LanguageRun: Equatable {
    public var text: String
    public var voice: RunVoice

    public init(_ text: String, _ voice: RunVoice) {
        self.text = text
        self.voice = voice
    }
}

/// Bilingual reading: the system voices read the other language badly (a Chinese voice spells or mangles English words,
/// an English voice skips Chinese), so those stretches go to the scheme's secondary voice.
///
/// Only words go to the secondary voice. For a Chinese main voice that is runs of Latin letters, with the apostrophes
/// and hyphens inside words ("don't", "Wi-Fi", not pronounced) and the spaces between words; for any other main voice
/// (Japanese excepted: its kanji are Han characters too) runs of Chinese characters with their punctuation. Digits and
/// symbols always stay with the main voice: a phone number or "MP3"'s 3 in English inside Chinese, or "Node.js"'s dot
/// and "user@example.com"'s @ read (or swallowed) by the English voice, sounded wrong. Punctuation that only marks a
/// pause (sentence and clause ends, quotes, brackets) is not read out: it stays with the stretch before it, whose voice
/// makes the pause; a dot inside a word ("Node.js", "example.com") is read out by the main voice instead.
public enum LanguageRuns {
    public static func split(_ text: String, mainLanguage: String) -> [LanguageRun] {
        let raw: [Piece]
        if isChinese(mainLanguage) {
            raw = latinRuns(Array(text))
        } else if mainLanguage.hasPrefix("ja") {
            return [LanguageRun(text, .main)]
        } else {
            raw = hanRuns(Array(text))
        }
        return merged(raw, whole: text)
    }

    /// Chinese of any kind: Mandarin (zh-CN, zh-TW) and Cantonese, which the system voices call "yue-HK" (older systems
    /// "zh-HK").
    public static func isChinese(_ language: String) -> Bool { language.hasPrefix("zh") || language.hasPrefix("yue") }

    /// A letter of the Latin script, accented ones too ("café", "Pokémon", "Zürich"), so a word stays with one voice.
    static func isLatin(_ c: Character) -> Bool {
        guard c.isLetter, let v = c.unicodeScalars.first?.value else { return false }
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0xC0...0x24F).contains(v) || (0x1E00...0x1EFF).contains(v)
    }

    static func isHan(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2EBEF).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }

    /// Chinese punctuation and full-width punctuation: they belong with the Chinese text around them. Not full-width
    /// letters and digits ("１０"): those are read like their plain forms.
    static func isCJKPunct(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, !c.isLetter, !c.isNumber else { return false }
        return (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) || "“”‘’…—·".contains(c)
    }

    /// A stretch whose only letter is one Latin capital: lower-cased. The system voices read a capital standing alone
    /// as "capital C" (Samantha) or "大写C" (Tingting), measured; with the stretch around it, or lower-cased, just "C".
    public static func lowercasingLoneCapital(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        guard letters.count == 1, let c = letters.first, isLatin(c), c.isUppercase else { return s }
        return s.lowercased()
    }

    /// Marks a pause only (the punctuation NVDA's Dual Voice add-on calls "complex"): never read out on its own.
    static func isPausePunct(_ c: Character) -> Bool { ",.!?;:…\"'`()«»-".contains(c) || isCJKPunct(c) }

    /// Something to read: a letter, a digit or a symbol (@ # / & …), not just spaces and pause punctuation.
    static func speakable(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber || !($0.isWhitespace || isPausePunct($0)) }
    }

    /// A stretch before merging. `spoken`: it has something to read out (see `speakable`), or it is the dot inside a word.
    private struct Piece {
        var text: String
        var voice: RunVoice
        var spoken: Bool
    }

    private static func latinRuns(_ chars: [Character]) -> [Piece] {
        var out: [Piece] = []
        var cur = ""
        func flushMain(beforeLatin: Bool) {
            guard !cur.isEmpty else { return }
            // the dot inside a word ("Node.js", "example.com") is read out, not a full stop
            let inWord = cur == "." && beforeLatin && out.last?.voice == .other
            out.append(Piece(text: cur, voice: .main, spoken: inWord || speakable(cur)))
            cur = ""
        }
        var i = 0
        while i < chars.count {
            guard isLatin(chars[i]) else {
                cur.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while true {
                while j < chars.count && isLatin(chars[j]) { j += 1 }
                // an apostrophe or hyphen inside a word is part of it
                if j + 1 < chars.count, "'’-".contains(chars[j]), isLatin(chars[j + 1]) {
                    j += 1
                    continue
                }
                // words joined by spaces
                var k = j
                while k < chars.count && chars[k] == " " { k += 1 }
                if k > j, k < chars.count, isLatin(chars[k]) {
                    j = k
                    continue
                }
                break
            }
            flushMain(beforeLatin: true)
            out.append(Piece(text: String(chars[i..<j]), voice: .other, spoken: true))
            i = j
        }
        flushMain(beforeLatin: false)
        return out
    }

    private static func hanRuns(_ chars: [Character]) -> [Piece] {
        var out: [Piece] = []
        var cur = ""
        var i = 0
        while i < chars.count {
            guard isHan(chars[i]) else {
                cur.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while j < chars.count {
                let c = chars[j]
                if isHan(c) || isCJKPunct(c) {
                    j += 1
                } else if c == " ", j + 1 < chars.count, isHan(chars[j + 1]) {
                    j += 1
                } else {
                    break
                }
            }
            if !cur.isEmpty { out.append(Piece(text: cur, voice: .main, spoken: speakable(cur))); cur = "" }
            out.append(Piece(text: String(chars[i..<j]), voice: .other, spoken: true))
            i = j
        }
        if !cur.isEmpty { out.append(Piece(text: cur, voice: .main, spoken: speakable(cur))) }
        return out
    }

    /// Fragments with nothing to read (spaces, pause punctuation) are glued to a neighbour; neighbours of one voice join.
    private static func merged(_ pieces: [Piece], whole: String) -> [LanguageRun] {
        var out: [Piece] = []
        for p in pieces {
            if var last = out.last, !p.spoken || last.voice == p.voice {
                last.text += p.text
                out[out.count - 1] = last
            } else {
                out.append(p)
            }
        }
        if out.count > 1, !out[0].spoken {
            let head = out.removeFirst()
            out[0].text = head.text + out[0].text
        }
        // spaces and pause punctuation between two runs end the first one: its last character decides the pause at the
        // switch (a stretch that is nothing but such a character, the dot inside a word, stays as it is, and so does
        // punctuation that leads into a symbol, the colon of "https://")
        for i in out.indices.dropFirst() {
            let lead = out[i].text.prefix { $0.isWhitespace || isPausePunct($0) }
            guard !lead.isEmpty, lead.count < out[i].text.count else { continue }
            let next = out[i].text[lead.endIndex]
            guard next.isLetter || next.isNumber else { continue }
            out[i - 1].text += lead
            out[i].text.removeFirst(lead.count)
        }
        return out.isEmpty ? [LanguageRun(whole, .main)] : out.map { LanguageRun($0.text, $0.voice) }
    }
}
