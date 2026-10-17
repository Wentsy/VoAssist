import Foundation

/// One user rule that changes the text before it is read: a misread polyphone replaced by a homophone ("重新" -> "虫新"),
/// an English word spelled the way the voice gets it right, a number pattern rewritten with a regular expression ...
public struct ReadingRule: Codable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var enabled = true
    /// Text to find, or an ICU regular expression when `regex` is on.
    public var find: String
    /// Replacement; with `regex` on, `$1`, `$2` ... insert the groups.
    public var replace: String
    public var regex = false
    public var ignoreCase = false
    /// Plain text only: match whole English words / numbers ("live" not inside "deliver"). Chinese characters around the
    /// match do not count as part of the word.
    public var wholeWord = false
    public var note = ""

    public init(find: String, replace: String, regex: Bool = false, ignoreCase: Bool = false, wholeWord: Bool = false,
                note: String = "", enabled: Bool = true) {
        self.find = find
        self.replace = replace
        self.regex = regex
        self.ignoreCase = ignoreCase
        self.wholeWord = wholeWord
        self.note = note
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, enabled, find, replace, regex, ignoreCase, wholeWord, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        find = try c.decode(String.self, forKey: .find)
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? ""
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// The compiled form, or why the rule cannot be used (shown in the app; such a rule is skipped when reading).
    public func compiled() -> Result<NSRegularExpression, RuleError> {
        guard !find.isEmpty else { return .failure(.emptyFind) }
        var pattern = regex ? find : NSRegularExpression.escapedPattern(for: find)
        if !regex && wholeWord { pattern = "(?<![A-Za-z0-9])" + pattern + "(?![A-Za-z0-9])" }
        do {
            return .success(try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []))
        } catch {
            return .failure(.badPattern)
        }
    }

    var template: String { regex ? replace : NSRegularExpression.escapedTemplate(for: replace) }

    public enum RuleError: Error, Equatable {
        case emptyFind, badPattern

        public var message: String {
            switch self {
            case .emptyFind: return "“查找”不能为空"
            case .badPattern: return "正则表达式写得不对"
            }
        }
    }

    /// A few rules showing what rules can do; added switched off.
    public static let examples: [ReadingRule] = [
        ReadingRule(find: "重新", replace: "虫新", note: "示例：多音字用同音字替换，让“重”读 chóng", enabled: false),
        ReadingRule(find: "iOS", replace: "eye O S", ignoreCase: true, wholeWord: true, note: "示例：英文整词读法修正", enabled: false),
        ReadingRule(find: "(\\d+(?:\\.\\d+)?)%", replace: "百分之$1", regex: true, note: "示例：正则，50% 读成 百分之50", enabled: false),
        ReadingRule(find: "(?<!\\d)(1[3-9]\\d)(\\d{4})(\\d{4})(?!\\d)", replace: "$1 $2 $3", regex: true, note: "示例：正则，手机号按 3-4-4 分组读", enabled: false),
        ReadingRule(find: "★", replace: "", note: "示例：某个符号不读", enabled: false),
    ]
}

/// The enabled, valid rules in order, ready to apply.
public struct RuleBook {
    private let compiled: [(NSRegularExpression, String)]

    public init(_ rules: [ReadingRule]) {
        compiled = rules.filter(\.enabled).compactMap { r in
            guard case .success(let re) = r.compiled() else { return nil }
            return (re, r.template)
        }
    }

    public var isEmpty: Bool { compiled.isEmpty }

    /// Applies every rule to the result of the one before.
    public func apply(_ text: String) -> String {
        var t = text
        for (re, template) in compiled {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t
    }

    // MARK: shared file

    public static func loadRules() -> [ReadingRule] { loadRulesIfOpen() ?? [] }

    /// nil while the file is there but cannot be read (see `VoiceScheme.loadIfOpen`).
    static func loadRulesIfOpen() -> [ReadingRule]? {
        SharedStore.readList(ReadingRule.self, "rules.json") ?? (SharedStore.exists("rules.json") ? nil : [])
    }

    @discardableResult
    public static func save(_ rules: [ReadingRule]) -> Bool { SharedStore.write(rules, "rules.json") }

    private static let lock = NSLock()
    private static var cache: (Date?, RuleBook)?

    /// The shared rules, compiled once per change of the file (the extension asks for every request); a file that cannot
    /// be read yet is not cached (see `VoiceScheme.shared`).
    public static func shared() -> RuleBook {
        let date = SharedStore.modificationDate("rules.json")
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.0 == date { return c.1 }
        guard let rules = loadRulesIfOpen() else { return cache?.1 ?? RuleBook([]) }
        let book = RuleBook(rules)
        cache = (date, book)
        return book
    }
}
