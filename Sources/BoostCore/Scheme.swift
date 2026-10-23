import Foundation

/// A voice scheme: what the system lists as one of our voices. The user defines it in the app: a main Apple voice, an
/// optional secondary one for the other language, how much faster than VoiceOver's own rate, and so on.
public struct VoiceScheme: Codable, Identifiable, Equatable, Hashable {
    /// Stable: VoiceOver remembers the voice by it, so renaming or re-tuning a scheme keeps it selected.
    public var id = UUID()
    /// Shown as is in the system's voice list (under our app's group).
    public var name: String
    public var main: VoiceEntry
    /// Reads the other language: English inside a Chinese main voice's text, Chinese inside any other. nil = none.
    public var secondary: VoiceEntry?
    /// Speed-up on top of VoiceOver's rate, done by Sonic as in NVDA's rate boost, 1...6.
    public var boost = 1.0
    /// The secondary voice's speed relative to the main one, 0.5...2.
    public var secondaryRate = 1.0
    /// Match the secondary voice's loudness to the main one's (on unless the user turns it off).
    public var balanceVolume = true
    /// The gain (dB) that does it, measured by the app; nil = not measured yet (no change).
    public var secondaryGainDB: Double?
    /// Apply the (global) reading rules.
    public var useRules = true
    /// How numbers are read (see `NumberReading`).
    public var numbers = NumberReading.system

    public static let boostRange = 1.0...6.0
    public static let secondaryRateRange = 0.5...2.0
    public static let maxBalanceDB = 12.0

    public init(id: UUID = UUID(), name: String, main: VoiceEntry, secondary: VoiceEntry?) {
        self.id = id
        self.name = name
        self.main = main
        self.secondary = secondary
    }

    enum CodingKeys: String, CodingKey { case id, name, main, secondary, boost, secondaryRate, balanceVolume, secondaryGainDB, useRules, numbers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        main = try c.decode(VoiceEntry.self, forKey: .main)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? main.name
        secondary = try c.decodeIfPresent(VoiceEntry.self, forKey: .secondary)
        boost = try c.decodeIfPresent(Double.self, forKey: .boost) ?? 1
        secondaryRate = try c.decodeIfPresent(Double.self, forKey: .secondaryRate) ?? 1
        balanceVolume = try c.decodeIfPresent(Bool.self, forKey: .balanceVolume) ?? true
        secondaryGainDB = try c.decodeIfPresent(Double.self, forKey: .secondaryGainDB)
        useRules = try c.decodeIfPresent(Bool.self, forKey: .useRules) ?? true
        // a reading a later version added is not a broken scheme
        numbers = (try? c.decodeIfPresent(String.self, forKey: .numbers)).flatMap(NumberReading.init(rawValue:)) ?? .system
    }

    /// The language list the scheme appears in.
    public var language: String { main.lang }

    /// The languages the scheme is offered for: its main voice's; a Chinese one also for the other spoken Chinese ones
    /// VoiceOver keeps a voice for. VoiceOver reads text tagged with another of them (the status bar in the system's
    /// Mandarin, under a Cantonese scheme) with the voice chosen for that one, which can then be the same scheme. The
    /// system files a voice under its first language only, so the scheme is one voice per language
    /// (`providerIdentifier(for:)`).
    public var offeredLanguages: [String] {
        guard LanguageRuns.isChinese(language) else { return [language] }
        return [language] + VoiceScheme.chineseLanguages.filter { $0 != language }
    }
    static let chineseLanguages = ["zh-CN", "zh-TW", "yue-HK"]

    /// Whether the secondary voice reads Latin text (a Chinese main voice) or Chinese characters (any other).
    public static func secondaryReadsEnglish(main lang: String) -> Bool { LanguageRuns.isChinese(lang) }

    /// A piece of text as the scheme reads it, before it is split between the voices: the reading rules (if it uses
    /// them, so that they still see the digits), then the numbers written out (if it asks for that).
    public func prepared(_ text: String, rules: RuleBook) -> String {
        Numbers.read(useRules ? rules.apply(text) : text, numbers, language: main.lang)
    }

    /// Gain applied to the secondary voice's samples (1 = unchanged).
    public var secondaryGain: Float {
        guard balanceVolume, let db = secondaryGainDB else { return 1 }
        return Float(pow(10, min(max(db, -VoiceScheme.maxBalanceDB), VoiceScheme.maxBalanceDB) / 20))
    }

    /// Values from a file or an older version brought into range.
    public func clamped() -> VoiceScheme {
        var s = self
        s.boost = min(max(boost, VoiceScheme.boostRange.lowerBound), VoiceScheme.boostRange.upperBound)
        s.secondaryRate = min(max(secondaryRate, VoiceScheme.secondaryRateRange.lowerBound), VoiceScheme.secondaryRateRange.upperBound)
        // only Apple's own voices, for the secondary one too (a provider voice, ours above all, would call back into one)
        if let o = s.secondary, !VoiceEntry.isWrappable(o.id) { s.secondary = nil }
        return s
    }

    // MARK: identifiers

    public static let providerPrefix = "com.zdyi.voassist.s."

    public var providerIdentifier: String { VoiceScheme.providerPrefix + id.uuidString }

    /// The scheme's voice in one of its `offeredLanguages`: in its own language the identifier it always had (so what
    /// VoiceOver has chosen stays), in another one with that language after it.
    public func providerIdentifier(for lang: String) -> String {
        lang == language ? providerIdentifier : providerIdentifier + "." + lang
    }

    /// The scheme behind one of its voices, whichever language it is in.
    public static func schemeID(fromProvider identifier: String) -> UUID? {
        guard identifier.hasPrefix(providerPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(providerPrefix.count).prefix(36)))
    }

    // MARK: defaults

    /// The default scheme has a fixed id, so the one the extension offers before the app first ran is the same voice
    /// VoiceOver keeps once the app has written its list. (Builds before 15 also had Samantha ...002 and 善怡 ...003;
    /// those ids stay unused.)
    /// This fork is signed without the App Group, so the app cannot save schemes: the one the user has is this default,
    /// compiled in. Its boost is what the user asked for (1.25×).
    public static let defaultTingting: VoiceScheme = {
        var s = VoiceScheme(id: UUID(uuidString: "5A1C0000-0000-4000-8000-000000000001")!, name: "婷婷+Samantha",
                            main: .tingting, secondary: .samantha)
        s.boost = 1.1
        s.secondaryRate = 0.9
        return s
    }()
    public static let defaults = [defaultTingting]

    // MARK: shared file

    static let file = "schemes.json"

    /// The app has never written its list (first launch): the defaults apply. An empty list is the user's choice.
    public static var neverSaved: Bool { !SharedStore.exists(file) }

    public static func load() -> [VoiceScheme] { loadIfOpen() ?? defaults }

    /// The saved list (the defaults if there is none); nil while there is one that cannot be read, as after a restart until
    /// the first unlock (see `SharedStore.write`).
    static func loadIfOpen() -> [VoiceScheme]? {
        guard let list = SharedStore.readList(VoiceScheme.self, file) else { return SharedStore.exists(file) ? nil : defaults }
        return list.filter { VoiceEntry.isWrappable($0.main.id) }.map { $0.clamped() }
    }

    @discardableResult
    public static func save(_ list: [VoiceScheme]) -> Bool { SharedStore.write(list, file) }

    private static let lock = NSLock()
    private static var cache: (Date?, Bool, [VoiceScheme])?

    /// The list, re-read only when the file changed (the extension asks for every request). A file that cannot be read
    /// yet is not cached, or what stood in for it would stay until the next change (the boost was lost after a restart
    /// until the scheme was edited): the last list read, or the defaults, until the next request reads it.
    public static func shared() -> [VoiceScheme] {
        let date = SharedStore.modificationDate(file)
        let exists = SharedStore.exists(file)
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.0 == date, c.1 == exists { return c.2 }
        guard let list = loadIfOpen() else { return cache?.2 ?? defaults }
        cache = (date, exists, list)
        return list
    }
}

/// What is exported and shared between users: schemes and/or rules, as versioned JSON text (also the `.voassist` file).
public struct ShareBundle: Codable, Equatable {
    public var format = "voassist"
    public var version = 1
    public var schemes: [VoiceScheme]?
    public var rules: [ReadingRule]?

    public init(schemes: [VoiceScheme]?, rules: [ReadingRule]?) {
        self.schemes = schemes
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case format, version, schemes, rules }

    /// Only `format` is required; a scheme or rule that cannot be read is left out, not the whole bundle.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        schemes = try c.decodeIfPresent([Lossy<VoiceScheme>].self, forKey: .schemes)?.compactMap(\.value)
        rules = try c.decodeIfPresent([Lossy<ReadingRule>].self, forKey: .rules)?.compactMap(\.value)
    }

    public func text() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let d = try? e.encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// A shared bundle, or a bare list of rules (what the first versions exported); nil if the text is neither.
    public static func parse(_ text: String) -> ShareBundle? {
        guard let d = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        if let b = try? JSONDecoder().decode(ShareBundle.self, from: d), b.format == "voassist", b.schemes != nil || b.rules != nil {
            return b
        }
        if let rules = try? JSONDecoder().decode([ReadingRule].self, from: d) {
            return ShareBundle(schemes: nil, rules: rules)
        }
        return nil
    }

    public struct Merged: Equatable {
        public var schemes: [VoiceScheme]
        public var rules: [ReadingRule]
        public var addedSchemes: Int
        public var addedRules: Int
        public var skippedRules: Int
    }

    /// Adds this bundle to what the user has: every scheme as a new one (fresh id; a name already used in its language
    /// gets "（2）", "（3）" ...), every rule not already there (same find, replacement and options) at the end.
    public func merged(into schemes: [VoiceScheme], rules: [ReadingRule]) -> Merged {
        var outSchemes = schemes
        for var s in self.schemes ?? [] where VoiceEntry.isWrappable(s.main.id) {
            s.id = UUID()
            s = s.clamped()
            let taken = Set(outSchemes.filter { $0.language == s.language }.map(\.name))
            if taken.contains(s.name) {
                var n = 2
                while taken.contains("\(s.name)（\(n)）") { n += 1 }
                s.name = "\(s.name)（\(n)）"
            }
            outSchemes.append(s)
        }
        var outRules = rules
        var skipped = 0
        for var r in self.rules ?? [] {
            if outRules.contains(where: { $0.sameEffect(as: r) }) {
                skipped += 1
                continue
            }
            r.id = UUID()
            outRules.append(r)
        }
        return Merged(schemes: outSchemes, rules: outRules, addedSchemes: outSchemes.count - schemes.count,
                      addedRules: outRules.count - rules.count, skippedRules: skipped)
    }
}

extension ReadingRule {
    /// Same find, replacement and options (enabled state and note do not count).
    public func sameEffect(as o: ReadingRule) -> Bool {
        find == o.find && replace == o.replace && regex == o.regex && ignoreCase == o.ignoreCase && wholeWord == o.wholeWord
    }
}
