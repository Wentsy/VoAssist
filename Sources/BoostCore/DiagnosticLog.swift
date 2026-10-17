import Foundation

/// The diagnostic log the user switches on in the app (for `duration` at most) and sends: what the voice extension did
/// for VoiceOver, call by call and request by request. The extension cannot write into the App Group, so it writes into
/// its own container, which all its processes share (VoiceOver's, the system's voice listing, the app's: measured on an
/// iPhone), and hands the text over through `AUAudioUnit.fullState` when the app asks (`commandKey`, `logKey`).
public enum DiagnosticLog {
    /// How long a switched-on log stays on.
    public static let duration: TimeInterval = 3600
    /// Each of the two files (the current one, the one before) is kept under this size.
    static let maxBytes = 1_000_000
    /// Spoken text is cut to this many characters.
    static let maxSpeech = 200

    /// The app writes a command under this key into the extension's `fullState`: `sendLog` (the next read carries the
    /// log under `logKey`) or `clearLog`.
    public static let commandKey = "voassist.command"
    public static let logKey = "voassist.log"

    /// The folder in the extension's own container (tests use one of their own).
    static var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diagnostics", isDirectory: true)
    static var current: URL { directory.appendingPathComponent("log.txt") }
    static var previous: URL { directory.appendingPathComponent("log.old.txt") }

    private static let lock = NSLock()
    private static var cached: (Date?, BoostSettings)?
    private static var introducedIn: ino_t = 0 // the file this process has said what it is in (a new one after clearing)
    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// The shared settings, re-read when the file changes (not cached while it cannot be read, see `VoiceScheme.shared`).
    private static func settings() -> BoostSettings {
        let date = SharedStore.modificationDate("settings.json")
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.0 == date { return c.1 }
        let s: BoostSettings
        if let read = SharedStore.read(BoostSettings.self, "settings.json") {
            s = read
        } else if SharedStore.exists("settings.json") {
            return cached?.1 ?? BoostSettings() // closed for now: the last settings read, and try again next time
        } else {
            s = BoostSettings()
        }
        cached = (date, s)
        return s
    }

    public static var isOn: Bool { settings().isLogging() }

    /// What VoiceOver reads, for the log: the text itself if the user asked for it (cut short), else only its length.
    public static func speech(_ text: String) -> String {
        let s = settings()
        guard s.isLogging() && s.logSpeech else { return "\(text.count) chars" }
        let t = text.count > maxSpeech ? String(text.prefix(maxSpeech)) + "…" : text
        return "\"\(t)\""
    }

    /// Appends a line, with the time and the process, while the log is on.
    public static func write(_ line: @autoclosure () -> String) {
        guard isOn else { return }
        append(line())
    }

    static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: current.path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        // opened for each line: another process may have moved the file away meanwhile; one write per line, appended
        let fd = open(current.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        func put(_ text: String) {
            let bytes = Array("\(stampFormat.string(from: Date())) [\(getpid())] \(text)\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_ino != introducedIn {
            introducedIn = st.st_ino
            put(processDescription)
        }
        put(line)
    }

    /// The first line a process writes into a file: what it is, which build, which system.
    static var processDescription: String {
        let info = Bundle.main.infoDictionary
        let p = ProcessInfo.processInfo
        return "process \(p.processName), \(Bundle.main.bundleIdentifier ?? "-") \(info?["CFBundleShortVersionString"] as? String ?? "-") (\(info?["CFBundleVersion"] as? String ?? "-")), \(p.operatingSystemVersionString)\(p.isiOSAppOnMac ? ", iPhone app on a Mac" : "")"
    }

    /// Everything recorded, oldest first.
    public static func contents() -> String {
        lock.lock(); defer { lock.unlock() }
        return [previous, current].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.removeItem(at: current)
    }
}
