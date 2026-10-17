import Foundation

/// Settings shared between the host app and the voice extension: plain JSON files in the App Group container (like the
/// open-source DECtalk voice: `UserDefaults(suiteName:)` is not reliably flushed across processes). The app writes them, the extension only reads them (on an iPhone a voice extension cannot write into the
/// group at all, neither files nor group defaults: measured).
public enum SharedStore {
    /// Must match `com.apple.security.application-groups` in both targets' entitlements (project.yml).
    public static let groupID = "group.com.zdyi.voassist"

    /// The App Group container; nil when the entitlement is missing. The Mac tools fall back to no file at all.
    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let u = container?.appendingPathComponent(name), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    /// A list whose unreadable entries are skipped: one bad entry must not cost the others (the next save would write
    /// the list back without them all). nil if there is no list at all.
    static func readList<T: Decodable>(_ type: T.Type, _ name: String) -> [T]? {
        read([Lossy<T>].self, name)?.compactMap(\.value)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, _ name: String) -> Bool {
        guard let u = container?.appendingPathComponent(name), let d = try? JSONEncoder().encode(value) else { return false }
        return (try? d.write(to: u, options: .atomic)) != nil
    }

    static func exists(_ name: String) -> Bool {
        guard let u = container?.appendingPathComponent(name) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    static func modificationDate(_ name: String) -> Date? {
        guard let u = container?.appendingPathComponent(name) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }
}

#if DEBUG
/// Development only: records lines the app measured in the App Group's Library folder, to be pulled off a connected
/// phone with `xcrun devicectl device copy from --domain-type appGroupDataContainer --source Library/<file>` (devicectl
/// reads only Library, Documents and tmp). The voice extension cannot write here; it logs instead.
public enum DebugRecord {
    public static func append(_ line: String, to file: String) {
        let path = "Library/" + file
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line
        var all = SharedStore.read([String].self, path) ?? []
        all.append(stamped)
        if all.count > 300 { all.removeFirst(all.count - 300) }
        SharedStore.write(all, path)
    }
}
#endif

/// The Apple voices the voice extension can really use. Its sandbox keeps it from the voice database, the asset daemon,
/// the accessibility voices service and Siri's speech service (`deny file-read-data .../voicedb.sqlite`, `deny
/// mach-lookup com.apple.mobileassetd.v2` ...: measured on an iPhone, iOS 27), so it gets only the voices built into
/// the system ("super-compact"), not the downloaded compact, enhanced or premium ones, nor Siri or Eloquence voices,
/// though the app sees and can pick those; a scheme with one of them was read by the language's built-in voice. The app
/// cannot tell which ones by itself either (a downloaded compact voice hides its built-in twin from the app), so the
/// extension reports its list through `AUAudioUnit.fullState` and the app keeps it here.
public enum UsableVoices {
    static let file = "usable-voices.json"
    /// The key of the list in the extension's `fullState`.
    public static let stateKey = "usableVoices"

    public static func load() -> [VoiceEntry]? { SharedStore.read([VoiceEntry].self, file) }

    @discardableResult
    public static func save(_ voices: [VoiceEntry]) -> Bool { SharedStore.write(voices, file) }
}

/// What applies to every scheme. (Trimming the silence before and after an utterance and shortening the pauses by the
/// boost were switches up to build 9; they are always on now, and the old values in settings.json are ignored.)
public struct BoostSettings: Codable, Equatable {
    /// Measured speed of the system voices per `AVSpeechUtterance.rate` (nil = the table measured on the Mac). Used to give
    /// a secondary voice its relative speed.
    public var rateMap: RateMap?

    enum CodingKeys: String, CodingKey { case rateMap }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateMap = try c.decodeIfPresent(RateMap.self, forKey: .rateMap)
    }

    public var effectiveRateMap: RateMap { rateMap ?? .measured }

    public static func load() -> BoostSettings { SharedStore.read(BoostSettings.self, "settings.json") ?? BoostSettings() }

    @discardableResult
    public static func save(_ s: BoostSettings) -> Bool { SharedStore.write(s, "settings.json") }
}

/// An Apple voice, as a scheme refers to it.
public struct VoiceEntry: Codable, Equatable, Hashable {
    /// The Apple voice's identifier (`com.apple.voice.compact.zh-CN.Tingting` ...).
    public var id: String
    /// Its name when it was chosen (shown when the voice is no longer installed).
    public var name: String
    /// BCP-47 language.
    public var lang: String

    public init(id: String, name: String, lang: String) {
        self.id = id
        self.name = name
        self.lang = lang
    }

    enum CodingKeys: String, CodingKey { case id, name, lang }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lang = try c.decode(String.self, forKey: .lang)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id.components(separatedBy: ".").last ?? id
    }

    /// Only Apple's own voices may be used: a third-party voice (ours above all) would call back into a provider.
    public static func isWrappable(_ appleID: String) -> Bool {
        appleID.hasPrefix("com.apple.") && !appleID.contains(".speech.synthesis.voice.") // novelty voices (Bells, Bubbles ...)
    }

    // The built-in ("super-compact") voices: the only kind the voice extension can use (see `UsableVoices`).
    public static let tingting = VoiceEntry(id: "com.apple.voice.super-compact.zh-CN.Tingting", name: "婷婷", lang: "zh-CN")
    public static let samantha = VoiceEntry(id: "com.apple.voice.super-compact.en-US.Samantha", name: "Samantha", lang: "en-US")
    /// Cantonese: the identifier says zh-HK, the language is yue-HK.
    public static let sinji = VoiceEntry(id: "com.apple.voice.super-compact.zh-HK.Sinji", name: "善怡", lang: "yue-HK")
}

/// An element of a list that decodes to nil instead of failing the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
