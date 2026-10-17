import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Plays a finished block of mono Float32 samples. Once it has played (or is stopped), the engine stops and the audio
/// session is let go: a running engine keeps the audio hardware busy, and drains the battery, as long as the app stays
/// in front.
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var current = 0 // the playback under way, so that an older one's end does not stop a newer one

    func play(_ samples: [Float], sampleRate: Double) {
        stop()
        guard !samples.isEmpty, let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if format != fmt {
            if engine.isRunning { engine.stop() }
            if format == nil { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            format = fmt
        }
        if !engine.isRunning {
            // it cannot start in the background or while a call has the audio: playing then would raise an exception
            do { try engine.start() } catch { stop(); return }
        }
        current += 1
        let id = current
        node.scheduleBuffer(buf, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.current == id else { return }
                self.stop()
            }
        }
        node.play()
    }

    func stop() {
        current += 1
        node.stop()
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension UTType {
    /// A shared file of schemes and rules (declared in the app's Info.plist).
    static let voassist = UTType(exportedAs: "com.zdyi.voassist.share")
}

/// What the "分享与导入" section exports.
enum ExportKind: String, CaseIterable, Identifiable {
    case all = "方案和规则"
    case schemes = "只导出方案"
    case rules = "只导出规则"
    var id: String { rawValue }
}

/// A share file, written when the share sheet asks for it.
struct ShareFile: Transferable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .voassist) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name).appendingPathExtension("voassist")
            try Data(file.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// How a preview is read.
enum PreviewMode {
    /// The scheme as VoiceOver will read it.
    case scheme
    /// The scheme's main voice as VoiceOver itself reads it (no speed-up, rules, secondary voice or trimming).
    case plainMain
}

/// Schemes, rules, global settings, the installed voices, preview, import/export and self-checks.
final class AppModel: ObservableObject {
    @Published var settings = BoostSettings.load() {
        didSet { if settings != oldValue { BoostSettings.save(settings) } }
    }
    /// The reading rules, in the order they apply (rules.json, read by the extension on its next request).
    @Published var rules = RuleBook.loadRules() {
        didSet { if rules != oldValue { RuleBook.save(rules) } }
    }
    /// The voice schemes, which the system lists as our voices.
    @Published private(set) var schemes: [VoiceScheme] = VoiceScheme.neverSaved ? [] : VoiceScheme.load()
    /// Every Apple voice on this phone that a scheme can use.
    @Published private(set) var systemVoices: [AVSpeechSynthesisVoice] = []
    /// The voices the voice extension can use, as it last reported them (see `UsableVoices`).
    @Published private(set) var usableVoices: [VoiceEntry] = UsableVoices.load() ?? []
    @Published var previewStatus = ""
    @Published var probeStatus = ""
    @Published var busy = false
    /// The last preview's audio (the self-test keeps it as a WAV).
    private(set) var lastPreview: [Float] = []

    private let voice = SystemVoice()
    private let player = PCMPlayer()
    private let work = DispatchQueue(label: "voassist.app.work") // SystemVoice blocks: never on the main thread
    private var loudness: [String: Double] = [:] // measured level per Apple voice (work queue only)

    var hasAppGroup: Bool { SharedStore.container != nil }

    // MARK: - voices

    /// Reads the installed voices; on the very first launch creates the default schemes; measures what is still missing.
    func refreshVoices() {
        SharedStore.openForLockScreen()
        systemVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { VoiceEntry.isWrappable($0.identifier) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
        if VoiceScheme.neverSaved {
            setSchemes(defaultSchemes())
        } else {
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        }
        turnBalanceOnOnce()
        refreshUsableVoices()
        if settings.rateMap == nil, let s = schemes.first { calibrate(entry: s.main) }
        for s in schemes where s.balanceVolume && s.secondaryGainDB == nil { measureBalance(s.id) }
    }

    /// Builds before 16 left the loudness match off unless asked for; it is on by default now. The schemes of an earlier
    /// install get it once, so that turning it off afterwards sticks.
    private func turnBalanceOnOnce() {
        let key = "balanceVolumeOnByDefault"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard schemes.contains(where: { !$0.balanceVolume }) else { return }
        setSchemes(schemes.map { s in
            var s = s
            s.balanceVolume = true
            return s
        })
    }

    /// Asks the voice extension which voices it can use (only the built-in ones, see `UsableVoices`) and keeps the answer.
    func refreshUsableVoices() {
        ExtensionProbe.usableVoices { list in
            DispatchQueue.main.async {
                guard let list = list, !list.isEmpty else { return }
                let sorted = list.sorted { ($0.lang, $0.name) < ($1.lang, $1.name) }
                if sorted != self.usableVoices {
                    self.usableVoices = sorted
                    UsableVoices.save(sorted)
                }
            }
        }
    }

    /// The voices a scheme can be given: those the voice extension can use; until it has said, the built-in voices the
    /// app sees (a downloaded voice may hide its built-in twin, so a few can be missing for a moment).
    var pickableVoices: [VoiceEntry] {
        usableVoices.isEmpty
            ? systemVoices.filter { $0.identifier.contains(".super-compact.") }.map(AppModel.entry)
            : usableVoices
    }

    func voices(language: String) -> [VoiceEntry] { pickableVoices.filter { $0.lang == language } }

    /// Languages that have voices a scheme can use.
    var languages: [String] {
        var seen = Set<String>()
        return pickableVoices.map(\.lang).filter { seen.insert($0).inserted }
    }

    static func displayName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .enhanced: return "\(v.name)（增强）"
        case .premium: return "\(v.name)（高音质）"
        default: return v.name
        }
    }

    static func entry(_ v: AVSpeechSynthesisVoice) -> VoiceEntry {
        VoiceEntry(id: v.identifier, name: displayName(v), lang: v.language)
    }

    /// Whether a scheme can be given this voice (see `pickableVoices`).
    func isInstalled(_ e: VoiceEntry) -> Bool { pickableVoices.contains { $0.id == e.id } }

    func voiceName(_ e: VoiceEntry) -> String { pickableVoices.first { $0.id == e.id }?.name ?? e.name }

    /// The default schemes (婷婷, Samantha, 善怡: built-in voices), those whose voices the extension has (all of them
    /// until it has said).
    func defaultSchemes() -> [VoiceScheme] {
        guard !usableVoices.isEmpty else { return VoiceScheme.defaults }
        return VoiceScheme.defaults.filter { isInstalled($0.main) }.map { d in
            var s = d
            if let o = d.secondary, !isInstalled(o) { s.secondary = nil }
            return s
        }
    }

    /// Default schemes the user deleted; "恢复默认方案" adds them back.
    var missingDefaults: [VoiceScheme] {
        defaultSchemes().filter { d in !schemes.contains { $0.id == d.id } }
    }

    // MARK: - schemes

    private func setSchemes(_ list: [VoiceScheme]) {
        let before = schemes.map { [$0.id.uuidString, $0.name, $0.language] }
        let first = VoiceScheme.neverSaved
        schemes = list
        VoiceScheme.save(list)
        // the system asks the extension again only when what it lists changed (it can take ~30 s to show in Settings)
        if first || before != list.map({ [$0.id.uuidString, $0.name, $0.language] }) {
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        }
    }

    /// Adds or replaces a scheme; measures the loudness match when it is wanted and not known.
    func save(_ scheme: VoiceScheme) {
        var list = schemes
        if let i = list.firstIndex(where: { $0.id == scheme.id }) { list[i] = scheme } else { list.append(scheme) }
        setSchemes(list)
        if scheme.balanceVolume && scheme.secondary != nil && scheme.secondaryGainDB == nil { measureBalance(scheme.id) }
    }

    func delete(_ id: UUID) { setSchemes(schemes.filter { $0.id != id }) }

    func move(_ id: UUID, by offset: Int) {
        guard let i = schemes.firstIndex(where: { $0.id == id }), schemes.indices.contains(i + offset) else { return }
        var list = schemes
        list.swapAt(i, i + offset)
        setSchemes(list)
    }

    func restoreDefaults() { setSchemes(schemes + missingDefaults) }

    /// Measures both voices of a scheme and stores the gain that matches the secondary one to the main one.
    private func measureBalance(_ id: UUID) {
        guard let s = schemes.first(where: { $0.id == id }), let other = s.secondary else { return }
        work.async { [voice] in
            func level(_ e: VoiceEntry) -> Double? {
                if let l = self.loudness[e.id] { return l }
                let l = Loudness.measure(voice: voice, entry: e)
                self.loudness[e.id] = l
                return l
            }
            guard let a = level(s.main), let b = level(other) else { return }
            let db = Loudness.balanceDB(main: a, secondary: b)
            DispatchQueue.main.async {
                guard var cur = self.schemes.first(where: { $0.id == id }), cur.main == s.main, cur.secondary == other else { return }
                cur.secondaryGainDB = db
                self.save(cur)
            }
        }
    }

    // MARK: - preview (the same pipeline as the extension, in the app's own process)

    /// What VoiceOver's text turns into for a scheme: the rules applied, split by voice ("【婷婷】打开【Samantha】Safari").
    func describe(_ text: String, scheme: VoiceScheme, rules list: [ReadingRule]? = nil) -> String {
        let runs = BoostSynthesis.pieces(text, scheme: scheme, rules: RuleBook(list ?? rules))
        if runs.isEmpty { return "（没有可读的内容）" }
        return runs.map { r in
            let e = r.voice == .main ? scheme.main : (scheme.secondary ?? scheme.main)
            return "【\(voiceName(e))】\(r.text)"
        }.joined()
    }

    /// Reads `text` with `scheme` as VoiceOver at `voPercent` would. `rules` replaces the saved ones (to try a rule).
    func preview(text: String, scheme: VoiceScheme, voPercent: Double, mode: PreviewMode = .scheme, rules list: [ReadingRule]? = nil) {
        player.stop()
        var sc = scheme
        let s = settings
        if mode == .plainMain {
            sc.boost = 1
            sc.secondary = nil
            sc.useRules = false
        }
        let book = RuleBook(list ?? rules)
        previewStatus = "正在合成…"
        let ssml = VoiceOverRate.previewSSML(text, percent: voPercent)
        work.async { [voice] in
            var out: [Float] = []
            let status = BoostSynthesis.run(ssml: ssml, scheme: sc, settings: s, rules: book, voice: voice, isCancelled: { false }) { out += $0 }
            DispatchQueue.main.async {
                self.lastPreview = out
                if status == .ok {
                    let what = mode == .plainMain ? "旁白直接用\(self.voiceName(sc.main))" : "方案“\(sc.name)”，加速 \(times(sc.boost))"
                    self.previewStatus = String(format: "%@，旁白语速 %d%%：%.1f 秒", what, Int(voPercent), Double(out.count) / Double(SystemVoice.sampleRate))
                    self.player.play(out, sampleRate: Double(SystemVoice.sampleRate))
                } else {
                    self.previewStatus = "合成失败：\(status)"
                }
            }
        }
    }

    /// A voice's own sound, for picking it from a list.
    func sample(_ e: VoiceEntry) {
        let text = LanguageRuns.isChinese(e.lang) ? "你好，这是我的声音。" : "Hello, this is my voice."
        preview(text: text, scheme: VoiceScheme(name: e.name, main: e, secondary: nil), voPercent: 50, mode: .plainMain)
    }

    // MARK: - rules

    func addRules(_ new: [ReadingRule]) { rules.append(contentsOf: new) }

    func moveRule(_ id: UUID, by offset: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard rules.indices.contains(j) else { return }
        rules.swapAt(i, j)
    }

    // MARK: - sharing

    func exportText(_ kind: ExportKind) -> String {
        ShareBundle(schemes: kind == .rules ? nil : schemes, rules: kind == .schemes ? nil : rules).text()
    }

    func exportFile(_ kind: ExportKind) -> ShareFile {
        let name = kind == .rules ? "旁白助手规则" : (kind == .schemes ? "旁白助手方案" : "旁白助手方案和规则")
        return ShareFile(text: exportText(kind), name: name)
    }

    /// Imports shared text; returns what happened, for the user.
    func importText(_ text: String) -> String {
        guard let bundle = ShareBundle.parse(text) else { return "这不是旁白助手的方案或规则" }
        let m = bundle.merged(into: schemes, rules: rules)
        setSchemes(m.schemes)
        rules = m.rules
        for s in m.schemes.suffix(m.addedSchemes) where s.balanceVolume && s.secondary != nil { measureBalance(s.id) }
        var parts: [String] = []
        if bundle.schemes != nil { parts.append("导入 \(m.addedSchemes) 个方案") }
        if bundle.rules != nil {
            parts.append("导入 \(m.addedRules) 条规则" + (m.skippedRules > 0 ? "（\(m.skippedRules) 条已有，跳过）" : ""))
        }
        let missing = Set(m.schemes.suffix(m.addedSchemes).flatMap { [$0.main] + ($0.secondary.map { [$0] } ?? []) }.filter { !isInstalled($0) })
        if !missing.isEmpty {
            parts.append("这台手机缺少声音：\(missing.map(\.name).sorted().joined(separator: "、"))，暂用同语言的默认声音")
        }
        return parts.joined(separator: "；") + "。"
    }

    func importFile(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { return "读不到这个文件。" }
        return importText(String(decoding: d, as: UTF8.self))
    }

    // MARK: - self-checks

    func probeExtension(text: String, scheme: VoiceScheme, play: Bool = true, done: ((ExtensionProbe.Result) -> Void)? = nil) {
        probeStatus = "正在检查语音扩展…"
        busy = true
        ExtensionProbe.run(text: text, scheme: scheme) { r in
            DispatchQueue.main.async {
                self.measureSwitching(scheme: scheme) { lines in
                    var r = r
                    r.lines += lines
                    self.busy = false
                    self.probeStatus = r.lines.joined(separator: "\n")
                    if play && r.ok { self.player.play(r.samples, sampleRate: r.sampleRate) }
                    done?(r)
                }
            }
        }
    }

    /// How long the system voices take to switch voices in the middle of a sentence on this phone, and whether the
    /// extension's player would keep going through it (it holds back while a switch is under way).
    func measureSwitching(scheme: VoiceScheme, done: @escaping ([String]) -> Void) {
        guard scheme.secondary != nil else {
            DispatchQueue.main.async { done(["方案“\(scheme.name)”没有副语音，不用换声音"]) }
            return
        }
        let s = settings
        let book = RuleBook(rules)
        let text = VoiceScheme.secondaryReadsEnglish(main: scheme.main.lang) ? "打开 Safari 浏览器，然后连接 Wi-Fi 和 Bluetooth。"
                                                                                : "Open 微信 and 设置, then 蓝牙."
        work.async { [voice] in
            var lines = ["换声音（\(text)）："]
            for vo in [50.0, 100.0] {
                var check = PlaybackCheck()
                let status = BoostSynthesis.run(ssml: VoiceOverRate.previewSSML(text, percent: vo), scheme: scheme, settings: s, rules: book,
                                                voice: voice, isCancelled: { false }, switching: { check.setSwitching($0) }) { check.add($0.count) }
                check.finish()
                let waits = voice.lastSwitchWaitsMs.map(String.init).joined(separator: "/")
                lines.append(status == .ok ? "旁白 \(Int(vo))%：每次换声音用时 \(waits) ms；\(check.summary)" : "旁白 \(Int(vo))%：合成失败 \(status)")
            }
            DispatchQueue.main.async { done(lines) }
        }
    }

    /// Measures how fast the system voices really get per `AVSpeechUtterance.rate` on this phone (for the secondary
    /// voices' relative speed).
    func calibrate(entry: VoiceEntry, done: (() -> Void)? = nil) {
        work.async { [voice] in
            let m = RateMap.calibrate(voice: voice, entry: entry)
            DispatchQueue.main.async {
                if let m = m { self.settings.rateMap = m }
                done?()
            }
        }
    }
}
