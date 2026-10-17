import Foundation

/// How a scheme reads numbers.
public enum NumberReading: String, Codable, CaseIterable {
    /// As the system voice does: it decides ("1234" as a value, "2024年" digit by digit, times, dates, phone numbers).
    case system
    /// Written out as values before the voice gets them: 1234 → 一千两百三十四 / one thousand two hundred thirty-four.
    case values
    /// Written out digit by digit: 1234 → 一二三四 / one two three four.
    case digits
}

/// Writes numbers out for the main voice (digits always stay with it, see `LanguageRuns`), so that it has no say in how
/// they are read. Chinese and English main voices get words; any other main voice gets digits apart ("1 2 3 4") when
/// read digit by digit, and keeps its own reading of values.
///
/// Values: an integer of up to 16 digits (Chinese; 15 in English), with or without thousands separators; decimals,
/// percentages and a minus sign. Left as the voice reads them, which is a value already: digit groups joined by
/// `- / : ~` (times, dates, phone numbers, fractions, ranges) and ordinals ("1st"). Read digit by digit all the same: a
/// leading zero ("007", "0571"), anything longer, the parts of "192.168.1.1" after the first dot of a decimal. A lone 2
/// before a measure word is 两 ("2个" → 两个, not "第2个" or "2年级"), and so is 2 before 百, 千, 万 and 亿.
public enum Numbers {
    public static func read(_ text: String, _ mode: NumberReading, language: String) -> String {
        guard mode != .system, text.contains(where: \.isNumber) else { return text }
        let s = halfWidth(text)
        let style: Style
        if LanguageRuns.isChinese(language) {
            style = .chinese(traditional: language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") || language.hasPrefix("yue"))
        } else if language.hasPrefix("en") {
            style = .english
        } else {
            return mode == .digits ? s.replacingOccurrences(of: "(?<=[0-9])(?=[0-9])", with: " ", options: .regularExpression) : s
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            var range = m.range
            let replacement: String
            if m.range(at: 1).location != NSNotFound {
                // joined digit groups: the voice's own reading, unless digit by digit
                guard mode == .digits else { continue }
                replacement = style.spelled(ns.substring(with: range))
            } else if m.range(at: 2).location != NSNotFound {
                continue // an ordinal
            } else if m.range(at: 3).location != NSNotFound {
                let parts = ns.substring(with: range).split(separator: ".").map(String.init)
                replacement = parts.map { mode == .digits ? style.digits($0) : style.integer($0) }.joined(separator: style.point)
            } else {
                let int = ns.substring(with: m.range(at: 4)).replacingOccurrences(of: ",", with: "")
                let frac = m.range(at: 5).location == NSNotFound ? nil : ns.substring(with: m.range(at: 5))
                let percent = m.range(at: 6).location != NSNotFound
                // a minus sign: not a hyphen after a word or a number ("Wi-Fi-6", "5-3")
                var negative = false
                if range.location > 0, "-−".contains(ns.substring(with: NSRange(location: range.location - 1, length: 1))) {
                    let before = range.location > 1 ? ns.substring(with: NSRange(location: range.location - 2, length: 1)).first : nil
                    if !(before.map { $0.isLetter || $0.isNumber } ?? false) {
                        negative = true
                        range = NSRange(location: range.location - 1, length: range.length + 1)
                    }
                }
                var words = mode == .digits ? style.digits(int) : style.integer(int)
                if let f = frac { words += style.point + style.digits(f) }
                if case .chinese(let t) = style, mode == .values, int == "2", frac == nil, !percent, !negative,
                   twoIsLiang(before: ns, at: range.location, after: range.location + range.length) {
                    words = t ? "兩" : "两"
                }
                replacement = style.signed(words, negative: negative, percent: percent)
            }
            guard range.location >= last else { continue }
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            out += style.padded(replacement, in: ns, range: range)
            last = range.location + range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 1: digit groups joined by - / : ~ (with a percent sign after); 2: an ordinal; 3: a dotted chain (an address, a
    /// version); 4-6: a number (thousands separators allowed), its decimals, a percent sign.
    private static let pattern = try! NSRegularExpression(pattern:
        "([0-9]+(?:\\.[0-9]+)?(?:[-/:~～–][0-9]+(?:\\.[0-9]+)?)+%?)"
        + "|([0-9]+(?i:st|nd|rd|th)(?![A-Za-z]))"
        + "|([0-9]+(?:\\.[0-9]+){2,})"
        + "|([0-9]{1,3}(?:,[0-9]{3})+(?![0-9])|[0-9]+)(?:\\.([0-9]+))?(%)?")

    /// Full-width digits and percent sign as plain ones ("１０％").
    static func halfWidth(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0xFF10...0xFF19).contains($0.value) || $0.value == 0xFF05 }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0xFF10...0xFF19).contains(u.value) || u.value == 0xFF05 ? Unicode.Scalar(u.value - 0xFEE0)! : u
        }))
    }

    /// Measure words after which a lone 2 is 两 (simplified and traditional), and the beginnings where it is not.
    private static let measureWords = Set("个位只条张本件次天年周岁块元份台部辆首页种杯瓶倍名人家项款分秒小点节场篇句行组套对双把支根颗片封遍下斤米克公百千万亿"
        + "個隻條張週歲塊臺輛頁種節場組對雙顆萬億點")
    private static let notLiang = ["年级", "年級"]

    private static func twoIsLiang(before ns: NSString, at start: Int, after end: Int) -> Bool {
        if start > 0, ns.substring(with: NSRange(location: start - 1, length: 1)) == "第" { return false }
        guard end < ns.length, let next = ns.substring(with: NSRange(location: end, length: 1)).first, measureWords.contains(next) else { return false }
        let two = ns.substring(with: NSRange(location: end, length: min(2, ns.length - end)))
        return !notLiang.contains(two)
    }

    enum Style {
        case chinese(traditional: Bool)
        case english

        var point: String {
            switch self {
            case .chinese(let t): return t ? "點" : "点"
            case .english: return " point "
            }
        }

        func digits(_ d: String) -> String {
            switch self {
            case .chinese: return d.compactMap { $0.wholeNumberValue.map { Numbers.zhDigits[$0] } }.joined()
            case .english: return d.compactMap { $0.wholeNumberValue.map { Numbers.enOnes[$0] } }.joined(separator: " ")
            }
        }

        /// A whole number as a value; digit by digit with a leading zero or too many digits to say.
        func integer(_ d: String) -> String {
            guard !(d.count > 1 && d.hasPrefix("0")) else { return digits(d) }
            switch self {
            case .chinese(let t): return d.count <= 16 ? Numbers.zhInteger(d.compactMap(\.wholeNumberValue), traditional: t) : digits(d)
            case .english: return d.count <= 15 ? Numbers.enInteger(d.compactMap(\.wholeNumberValue)) : digits(d)
            }
        }

        /// Digit by digit, whatever lies between the digits kept (a dot between them read as the point).
        func spelled(_ s: String) -> String {
            var out: [String] = []
            var run = ""
            func flush() { if !run.isEmpty { out.append(digits(run)); run = "" } }
            let chars = Array(s)
            var percent = false
            for (i, c) in chars.enumerated() {
                if c.isASCII && c.isNumber { run.append(c); continue }
                flush()
                if c == "%" && i == chars.count - 1 { percent = true } else { out.append(c == "." ? point.trimmingCharacters(in: .whitespaces) : String(c)) }
            }
            flush()
            let body: String
            switch self {
            case .chinese: body = out.joined()
            case .english: body = out.joined(separator: " ")
            }
            return signed(body, negative: false, percent: percent)
        }

        func signed(_ words: String, negative: Bool, percent: Bool) -> String {
            switch self {
            case .chinese(let t):
                return (negative ? (t ? "負" : "负") : "") + (percent ? "百分之" : "") + words
            case .english:
                return (negative ? "minus " : "") + words + (percent ? " percent" : "")
            }
        }

        /// English words are kept apart from letters and digits next to them ("MP3" → "MP three").
        func padded(_ words: String, in ns: NSString, range: NSRange) -> String {
            guard case .english = self else { return words }
            func wordy(_ i: Int) -> Bool {
                guard i >= 0, i < ns.length, let c = ns.substring(with: NSRange(location: i, length: 1)).first else { return false }
                return LanguageRuns.isLatin(c) || c.isNumber
            }
            return (wordy(range.location - 1) ? " " : "") + words + (wordy(range.location + range.length) ? " " : "")
        }
    }

    static let zhDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// Up to 16 digits, without a leading zero: 万/亿 groups of four, 零 for the gaps, 十二 (not 一十二) in front, 两 before
    /// 百 and 千, and a group of just 2 before 万 or 亿 (两万, but 十二万).
    static func zhInteger(_ d: [Int], traditional t: Bool) -> String {
        if d.allSatisfy({ $0 == 0 }) { return "零" }
        var groups: [Int] = [] // lowest first
        var rest = d[...]
        while !rest.isEmpty {
            groups.append(rest.suffix(4).reduce(0) { $0 * 10 + $1 })
            rest = rest.dropLast(4)
        }
        let big = ["", t ? "萬" : "万", t ? "億" : "亿", t ? "萬億" : "万亿"]
        let liang = t ? "兩" : "两"
        var out = ""
        var gap = false
        for i in groups.indices.reversed() {
            let v = groups[i]
            if v == 0 { if !out.isEmpty { gap = true }; continue }
            if !out.isEmpty && (gap || v < 1000) { out += "零" }
            gap = false
            let ds = [v / 1000, v / 100 % 10, v / 10 % 10, v % 10]
            let units = ["千", "百", "十", ""]
            var s = ""
            var started = false
            var zero = false
            for k in 0..<4 {
                let x = ds[k]
                if x == 0 { if started { zero = true }; continue }
                if zero { s += "零"; zero = false }
                if k == 2 && x == 1 && !started && out.isEmpty {
                    s += "十" // 十二, not 一十二
                } else if x == 2 && (k < 2 || (v == 2 && i > 0)) {
                    s += liang + units[k]
                } else {
                    s += zhDigits[x] + units[k]
                }
                started = true
            }
            out += s + big[i]
        }
        return out
    }

    static let enOnes = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                         "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let enTens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Up to 15 digits, without a leading zero, American style (no "and").
    static func enInteger(_ d: [Int]) -> String {
        if d.allSatisfy({ $0 == 0 }) { return "zero" }
        var groups: [Int] = [] // lowest first
        var rest = d[...]
        while !rest.isEmpty {
            groups.append(rest.suffix(3).reduce(0) { $0 * 10 + $1 })
            rest = rest.dropLast(3)
        }
        let scales = ["", "thousand", "million", "billion", "trillion"]
        var parts: [String] = []
        for i in groups.indices.reversed() where groups[i] > 0 {
            let v = groups[i]
            if v >= 100 { parts.append(enOnes[v / 100] + " hundred") }
            let r = v % 100
            if r >= 20 {
                parts.append(enTens[r / 10] + (r % 10 > 0 ? "-" + enOnes[r % 10] : ""))
            } else if r > 0 {
                parts.append(enOnes[r])
            }
            if i > 0 { parts.append(scales[i]) }
        }
        return parts.joined(separator: " ")
    }
}
