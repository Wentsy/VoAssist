import AVFoundation
import SwiftUI
import UIKit

@main
struct VoAssistApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

func times(_ v: Double) -> String { String(format: "%g 倍", (v * 100).rounded() / 100) }

extension View {
    /// VoiceOver swipe up/down changes the value by `step` (a plain Slider jumps by 10 % of its range).
    func adjustable(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value.wrappedValue = min(value.wrappedValue + step, range.upperBound)
            case .decrement: value.wrappedValue = max(value.wrappedValue - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// A labelled slider with VoiceOver steps.
struct TimesSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: (Double) -> String = times

    var body: some View {
        // one VoiceOver stop: the slider says its name and value; the text above is for the eyes only
        VStack(alignment: .leading) {
            Text("\(title)：\(format(value))")
                .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step) { Text(title) }
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
                .adjustable($value, in: range, step: step)
        }
    }
}

private struct Editing: Identifiable {
    let scheme: VoiceScheme
    let isNew: Bool
    var id: UUID { scheme.id }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var editing: Editing?
    @State private var deleting: VoiceScheme?
    @State private var exportKind = ExportKind.all
    @State private var importing = false
    @State private var notice = ""
    @State private var now = Date() // for the log switch, which turns itself off
    #if DEBUG
    @State private var nativeProbe = NativeRateProbe()
    @State private var debugLine = ""
    #endif
    /// `-showRules` launch argument (development): open the rule list right away.
    @State private var showRules = ProcessInfo.processInfo.arguments.contains("-showRules")

    /// The outcome of a copy or an import, on screen and spoken: VoiceOver would not notice the line appear. A little
    /// later, as the file picker's closing moves VoiceOver's focus.
    private func show(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    var body: some View {
        NavigationStack {
            Form {
                schemesSection

                Section {
                    NavigationLink("朗读修正规则") { RulesView(model: model) }
                }

                shareSection

                Section("使用方法") {
                    Text("""
                    1. 在上面建好方案：选主语音、副语音和语速加倍。
                    2. 打开 设置 → 辅助功能 → 旁白 → 语音，在方案对应的语言里点开“旁白助手”，选择方案。
                    3. 旁白自己的语速滑块和转子照常用，管的是不加速时的快慢；加速在本 App 的方案里设置。
                    4. 新建或改名的方案最多要约 30 秒才会出现在系统列表里；一直不出现就重启一次手机。
                    """).font(.footnote)
                }

                logSection

                Section("关于") {
                    NavigationLink("开源许可") { LicenseView() }
                }

                #if DEBUG
                Section("调试") {
                    Button("测量旁白语速") { nativeProbe.measure { debugLine = $0 } }
                    if !debugLine.isEmpty { Text(debugLine).font(.footnote) }
                }
                #endif
            }
            .navigationTitle("旁白助手")
            .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { now = $0 }
            .navigationDestination(isPresented: $showRules) { RulesView(model: model) }
        }
        .sheet(item: $editing) { e in SchemeEditView(model: model, draft: e.scheme, isNew: e.isNew) }
        .alert("删除方案“\(deleting?.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let d = deleting { model.delete(d.id) } }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.voassist, .json, .plainText]) { result in
            if case .success(let url) = result { show(model.importFile(url)) }
        }
        .onOpenURL { url in show(model.importFile(url)) }
        .onAppear {
            model.refreshVoices()
            let args = ProcessInfo.processInfo.arguments
            // development output line by line (on a Mac `open --stdout` gives a file, which would hold it all back)
            if args.contains(where: { ["-autotest", "-latency", "-listVoices"].contains($0) }) { setvbuf(stdout, nil, _IOLBF, 0) }
            // development: switch the diagnostic log on (with what is read), empty it, print it
            if args.contains("-logOn") { model.setLogging(true) }
            if args.contains("-logSpeech") { model.settings.logSpeech = true }
            if args.contains("-clearLog") { model.clearDiagnostics { ok in print("LOG cleared: \(ok)") } }
            if args.contains("-printLog") {
                Task {
                    print(await model.diagnosticText())
                    print("LOG done")
                    devRunEnded()
                }
            }
            if args.contains("-autotest") { AutoTest.run(model) }
            if args.contains("-ssmlTest") { SSMLTest.run() }
            if args.contains("-switchTest") { SwitchTest.run() }
            if args.contains("-voiceCompare") { setvbuf(stdout, nil, _IOLBF, 0); VoiceCompare.run() }
            if args.contains("-latency") { LatencyProbe.run() }
            // development: the Chinese and English voices the app sees (the voice extension sees fewer)
            if args.contains("-listVoices") {
                for v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix("zh") || v.language.hasPrefix("yue") || v.language.hasPrefix("en") {
                    print("VOICE \(v.identifier) q\(v.quality.rawValue) \(v.language) \(v.name)")
                }
                ExtensionProbe.usableVoices { list in
                    print("VOICE usable (from the extension): " + (list.map { $0.map { "\($0.id) \($0.name)" }.joined(separator: ", ") } ?? "nil"))
                    print("VOICE done")
                }
            }
            // development: open the first scheme's editor (-editScheme), or its main-voice language list (-pickMain)
            if args.contains("-editScheme") || args.contains("-pickMain"), let s = model.schemes.first { editing = Editing(scheme: s, isNew: false) }
        }
    }

    private var schemesSection: some View {
        Section {
            ForEach(model.schemes) { s in
                Button { editing = Editing(scheme: s, isNew: false) } label: { schemeRow(s) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "上移") { model.move(s.id, by: -1) }
                    .accessibilityAction(named: "下移") { model.move(s.id, by: 1) }
                    .accessibilityAction(named: "删除") { deleting = s }
                    .swipeActions { Button("删除", role: .destructive) { deleting = s } }
            }
            Button("添加方案") {
                let main = model.schemes.first?.main ?? model.pickableVoices.first { $0.lang == "zh-CN" } ?? VoiceEntry.tingting
                let secondary = VoiceScheme.secondaryReadsEnglish(main: main.lang) ? VoiceEntry.samantha : VoiceEntry.tingting
                editing = Editing(scheme: VoiceScheme(name: "", main: main, secondary: model.isInstalled(secondary) ? secondary : nil), isNew: true)
            }
            if !model.missingDefaults.isEmpty {
                Button("恢复默认方案（\(model.missingDefaults.map(\.name).joined(separator: "、"))）") { model.restoreDefaults() }
            }
        } header: {
            Text("语音方案")
        }
    }

    /// The diagnostic log: on for an hour at most; what VoiceOver reads only when asked for each time.
    private var logSection: some View {
        Section {
            Toggle("记录日志", isOn: Binding(get: { model.isLogging(at: now) }, set: { on in
                model.setLogging(on)
                now = Date()
            }))
            Toggle("记录朗读内容", isOn: Binding(get: { model.isLogging(at: now) && model.settings.logSpeech },
                                           set: { model.settings.logSpeech = $0 }))
                .disabled(!model.isLogging(at: now))
            ShareLink(item: model.diagnosticFile(), preview: SharePreview("旁白助手日志")) {
                Text("发送日志")
            }
            Button("清空日志") {
                model.clearDiagnostics { ok in show(ok ? "日志已清空。" : "没能清空日志，请稍后再试。") }
            }
        } header: {
            Text("日志")
        }
    }

    private func schemeRow(_ s: VoiceScheme) -> some View {
        Text(s.name).foregroundColor(.primary)
    }

    private var shareSection: some View {
        Section {
            Picker("导出内容", selection: $exportKind) {
                ForEach(ExportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            Button("复制为文字") {
                UIPasteboard.general.string = model.exportText(exportKind)
                show("已复制，可以粘贴发给别人。")
            }
            ShareLink(item: model.exportFile(exportKind), preview: SharePreview(model.exportFile(exportKind).name)) {
                Text("分享文件")
            }
            Button("从剪贴板导入") { show(model.importText(UIPasteboard.general.string ?? "")) }
            Button("从文件导入") { importing = true }
            if !notice.isEmpty { Text(notice).font(.footnote) }
        } header: {
            Text("分享与导入")
        }
    }
}

/// A development run is over: on a Mac (the iPhone app there) the app quits, as nothing else ends it from the command line.
func devRunEnded() {
    if ProcessInfo.processInfo.isiOSAppOnMac { exit(0) }
}

/// `-ssmlTest` launch argument (development): VoiceOver-style requests, whole and with a part left out, through our
/// pipeline and straight to the system voice; the audio lengths show whether a part was read at all on this system.
enum SSMLTest {
    static func run() {
        Thread {
            func req(_ parts: [String]) -> String {
                "<speak><prosody rate=\"99.99998%\" volume=\"-1.9382001dB\">"
                    + parts.map { "<s><lang xml:lang=\"cmn-CN\">\($0)</lang></s>" }.joined() + "</prosody></speak>"
            }
            let cases: [(String, [String])] = [
                ("按住 说话|按钮", ["按住 说话", "按钮"]), ("说话|按钮", ["说话", "按钮"]), ("按住说话|按钮", ["按住说话", "按钮"]),
                ("已选定|微信|标签", ["已选定", "微信", "标签"]), ("已选定|标签", ["已选定", "标签"]),
                ("编辑框|可按住转文字", ["编辑框", "可按住转文字"]), ("可按住转文字", ["可按住转文字"]),
                ("1.2万|点赞", ["1.2万", "点赞"]), ("点赞", ["点赞"]),
                ("打开 Safari 浏览器", ["打开 Safari 浏览器"]), ("App Store|按钮", ["App Store", "按钮"]),
            ]
            let voice = SystemVoice()
            let scheme = VoiceScheme.defaultTingting
            guard let tingting = voice.resolve(scheme.main) else { print("SSMLTEST no voice"); return }
            voice.warmUp(scheme.main)
            for (name, parts) in cases {
                let ssml = req(parts)
                var ours = 0
                _ = BoostSynthesis.run(ssml: ssml, scheme: scheme, settings: BoostSettings(), rules: RuleBook([]), voice: voice,
                                       isCancelled: { false }) { ours += $0.count }
                var perVoice = 0
                let other = SystemVoice()
                _ = BoostSynthesis.runPerVoice(ssml: ssml, scheme: scheme, settings: BoostSettings(), rules: RuleBook([]), main: voice,
                                               other: other, isCancelled: { false }) { perVoice += $0.count }
                var apple: [Float] = []
                _ = voice.speak(ssml: ssml, voice: tingting, stretches: 1, isCancelled: { false }) { pcm, _ in apple += pcm }
                let lead = apple.firstIndex { abs($0) > 0.01 } ?? apple.count
                func ms(_ n: Int) -> Double { Double(n) / Double(SystemVoice.sampleRate) * 1000 }
                print(String(format: "SSMLTEST %@: ours %.0f ms, per voice %.0f ms, system voice alone %.0f ms (leading silence %.0f ms)", name,
                             ms(ours), ms(perVoice), ms(apple.count), ms(lead)))
            }
            print("SSMLTEST done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }
}

/// `-switchTest` launch argument (development): how long the first audio takes when items alternate between the main
/// and the secondary voice, with one synthesizer for both (as now) and with one per voice.
enum SwitchTest {
    static func run() {
        Thread {
            let main = VoiceEntry.tingting, other = VoiceEntry.samantha
            let items: [(String, Bool)] = [("打开", false), ("App Store", true), ("设置", false), ("Test Flight", true), ("相机", false),
                                           ("QQ", true), ("微信", false), ("Goodnotes", true), ("隐藏边栏", false), ("iPad", true)]
            func firstAudio(_ v: SystemVoice, _ e: VoiceEntry, _ text: String) -> Int {
                guard let voice = v.resolve(e) else { return -1 }
                let t0 = Date()
                var first = -1
                _ = v.speak(text, voice: voice, rate: 0.5, pitch: 1, isCancelled: { false }) { pcm in
                    if first < 0 && !pcm.isEmpty { first = Int(Date().timeIntervalSince(t0) * 1000) }
                }
                return first
            }
            let one = SystemVoice()
            one.warmUp(main); one.warmUp(other)
            let a = SystemVoice(), b = SystemVoice()
            a.warmUp(main); b.warmUp(other)
            for round in 0..<2 {
                var shared: [String] = [], separate: [String] = []
                for (text, english) in items {
                    shared.append("\(text) \(firstAudio(one, english ? other : main, text))")
                    separate.append("\(text) \(firstAudio(english ? b : a, english ? other : main, text))")
                }
                print("SWITCHTEST round \(round) one synthesizer: " + shared.joined(separator: ", "))
                print("SWITCHTEST round \(round) one per voice:   " + separate.joined(separator: ", "))
            }
            print("SWITCHTEST done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }
}

/// `-autotest` launch argument (simulator / development): scheme preview and the extension check, results on stdout.
enum AutoTest {
    static func run(_ model: AppModel) {
        print("AUTOTEST schemes: \(model.schemes.map { "\($0.name)[\($0.language)]" }.joined(separator: ", ")), app group: \(model.hasAppGroup)")
        let protection = SharedStore.sharedFiles.map { name in
            let a = SharedStore.container.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent(name).path) }
            return "\(name) \((a?[.protectionKey] as? FileProtectionType)?.rawValue ?? "-")"
        }
        print("AUTOTEST file protection: \(protection.joined(separator: ", "))")
        print("AUTOTEST languages: \(model.languages.sorted().joined(separator: " "))")
        guard var s = model.schemes.first(where: { $0.language == "zh-CN" }) ?? model.schemes.first else {
            print("AUTOTEST no schemes"); return
        }
        s.boost = 2
        model.save(s)
        if !model.rules.contains(where: { $0.find == "(\\d+(?:\\.\\d+)?)%" && $0.enabled }) {
            var r = ReadingRule.examples[2]
            r.enabled = true
            model.addRules([r])
        }
        let text = "设置，按钮。轻点两下以打开 Safari 浏览器，下载进度 50%。"
        print("AUTOTEST pieces: \(model.describe(text, scheme: s))")
        let shared = model.exportText(.all)
        print("AUTOTEST export: \(shared.count) characters, parses back: \(ShareBundle.parse(shared) != nil)")
        model.preview(text: text, scheme: s, voPercent: 100)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("AUTOTEST preview: \(model.previewStatus)")
            model.probeExtension(text: text, scheme: s, play: false) { r in
                print("AUTOTEST probe:\n\(r.lines.joined(separator: "\n"))")
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? WAV.data(r.samples, sampleRate: Int(r.sampleRate)).write(to: docs.appendingPathComponent("probe.wav"))
                try? WAV.data(model.lastPreview, sampleRate: SystemVoice.sampleRate).write(to: docs.appendingPathComponent("preview.wav"))
                print("AUTOTEST wav: \(docs.path)")
                print("AUTOTEST done ok=\(r.ok)")
                devRunEnded()
            }
        }
    }
}

/// Sonic's license, which its Apache 2.0 terms ask to pass on with the app.
struct LicenseView: View {
    private var license: String {
        Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("语速加倍使用 Sonic 语音变速库（作者 Bill Cox，https://github.com/waywardgeek/sonic），与 NVDA 的“语速加倍”是同一版本，未作修改。Sonic 按 Apache 2.0 许可证发布，全文如下。")
                Text(license).font(.footnote.monospaced()).textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("开源许可")
    }
}
