import AVFoundation
import SwiftUI

/// Language names and order for the voice pickers: the common ones first, the rest by name.
enum Languages {
    /// Shown first, in this order, when the phone has voices for them.
    static let common = ["zh-CN", "zh-TW", "yue-HK", "zh-HK", "en-US", "en-GB"]

    static func name(_ code: String) -> String {
        switch code {
        case "zh-CN": return "简体中文 · 普通话"
        case "zh-TW": return "繁体中文 · 台湾"
        case "yue-HK", "zh-HK": return "繁体中文 · 粤语（香港）"
        case "en-US": return "英语（美国）"
        case "en-GB": return "英语（英国）"
        default: return Locale.current.localizedString(forIdentifier: code) ?? code
        }
    }

    /// (common, others) among `codes`.
    static func split(_ codes: [String]) -> ([String], [String]) {
        let set = Set(codes)
        let first = common.filter(set.contains)
        let rest = codes.filter { !common.contains($0) }.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return (first, rest)
    }
}

/// Which voice of a scheme is being picked.
enum VoiceRole: Hashable {
    case main
    /// The secondary voice of a scheme whose main voice speaks `mainLanguage`.
    case secondary(mainLanguage: String)

    var title: String {
        switch self {
        case .main: return "主语音"
        case .secondary: return "副语音"
        }
    }

    /// The languages it may be: a secondary voice reads the other language (anything but Chinese for a Chinese main
    /// voice, Chinese for any other).
    func allows(_ code: String) -> Bool {
        switch self {
        case .main: return true
        case .secondary(let l): return VoiceScheme.secondaryReadsEnglish(main: l) ? !LanguageRuns.isChinese(code) : LanguageRuns.isChinese(code)
        }
    }
}

private enum Route: Hashable {
    case languages(VoiceRole)
    case voices(VoiceRole, String)
}

/// Creates or edits a scheme. While an existing scheme is edited, every change takes effect at once (VoiceOver's next
/// item already reads with it, to try it out), bar the name and a main voice of another language (they change the
/// system's voice list). "取消" (or swiping the sheet away) puts the scheme back as it was saved; "保存" keeps it. A new
/// scheme is added only with "保存".
struct SchemeEditView: View {
    @ObservedObject var model: AppModel
    @State var draft: VoiceScheme
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var confirmMove = false
    @AppStorage("previewVOPercent") private var voPercent = 50.0
    @State private var sample = ""
    /// The scheme as saved when the editor opened (nil for a new one): what "取消" goes back to.
    @State private var saved: VoiceScheme?
    @State private var finished = false // saved or deleted: nothing to undo

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("方案名称", text: $draft.name)
                } header: {
                    Text("名称")
                }

                Section {
                    voiceRow(.main, entry: draft.main)
                    voiceRow(.secondary(mainLanguage: draft.main.lang), entry: draft.secondary)
                } header: {
                    Text("声音")
                }

                Section {
                    TimesSlider(title: "语速加倍", value: $draft.boost, range: VoiceScheme.boostRange, step: 0.25)
                } header: {
                    Text("语速")
                }

                if draft.secondary != nil {
                    Section {
                        TimesSlider(title: "副语音相对语速", value: $draft.secondaryRate, range: VoiceScheme.secondaryRateRange, step: 0.1)
                        Toggle("副语音音量平衡", isOn: $draft.balanceVolume)
                    } header: {
                        Text("副语音")
                    }
                }

                Section {
                    Toggle("使用修正规则", isOn: $draft.useRules)
                    Picker("数字读法", selection: $draft.numbers) {
                        Text("默认").tag(NumberReading.system)
                        Text("数值").tag(NumberReading.values)
                        Text("数字").tag(NumberReading.digits)
                    }
                }

                Section {
                    TextField("要试听的文字", text: $sample, axis: .vertical)
                    TimesSlider(title: "试听时的旁白语速", value: $voPercent, range: 0...100, step: 5, format: { "\(Int($0))%" })
                    Button("试听这个方案") { model.preview(text: sample, scheme: draft, voPercent: voPercent) }
                } header: {
                    Text("试听")
                }
            }
            .navigationTitle(isNew ? "新方案" : "编辑方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        revert()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let o = saved, o.language != draft.language { confirmMove = true } else { commit() }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .languages(let role):
                    LanguageListView(model: model, role: role, selected: selectedLanguage(role), path: $path) { e in choose(e, for: role) }
                case .voices(let role, let lang):
                    VoiceListView(model: model, role: role, language: lang, selectedID: selectedID(role)) { e in choose(e, for: role) }
                }
            }
            .alert("方案会移到“\(Languages.name(draft.language))”列表", isPresented: $confirmMove) {
                Button("保存") { commit() }
                Button("取消", role: .cancel) {}
            }
        }
        .onAppear {
            if !isNew && saved == nil { saved = model.schemes.first { $0.id == draft.id } }
            if ProcessInfo.processInfo.arguments.contains("-pickMain") && path.isEmpty { path = [.languages(.main)] }
            if sample.isEmpty {
                sample = VoiceScheme.secondaryReadsEnglish(main: draft.main.lang)
                    ? "周末我和朋友去看了 The Lion King，两张票一共 128 元。"
                    : "This weekend I watched 流浪地球 with a friend, and the two tickets cost 128 dollars."
            }
        }
        .onChange(of: draft) { _ in applyLive() }
        .onDisappear { revert() } // swiped away: as "取消"
    }

    /// The draft in effect for VoiceOver right away, with the saved name and language.
    private func applyLive() {
        guard let o = saved, !finished else { return }
        var live = withMeasuredGain(draft)
        live.name = o.name
        if live.main.lang != o.main.lang {
            live.main = o.main
            live.secondary = o.secondary
            live.secondaryGainDB = o.secondaryGainDB
        }
        if model.schemes.first(where: { $0.id == live.id }) != live { model.save(live) }
    }

    /// Back to the scheme as saved when the editor opened, unless it was saved or deleted since.
    private func revert() {
        guard let o = saved, !finished else { return }
        finished = true
        if model.schemes.first(where: { $0.id == o.id }) != o { model.save(o) }
    }

    /// The loudness match the app measured meanwhile for these same voices (the draft does not hear of it).
    private func withMeasuredGain(_ s: VoiceScheme) -> VoiceScheme {
        var s = s
        if s.secondaryGainDB == nil, let cur = model.schemes.first(where: { $0.id == s.id }), cur.main == s.main, cur.secondary == s.secondary {
            s.secondaryGainDB = cur.secondaryGainDB
        }
        return s
    }

    private func voiceRow(_ role: VoiceRole, entry: VoiceEntry?) -> some View {
        NavigationLink(value: Route.languages(role)) {
            LabeledContent(role.title, value: entry.map { model.voiceName($0) } ?? "不使用")
        }
    }

    private func selectedLanguage(_ role: VoiceRole) -> String? {
        role == .main ? draft.main.lang : draft.secondary?.lang
    }

    private func selectedID(_ role: VoiceRole) -> String? {
        role == .main ? draft.main.id : draft.secondary?.id
    }

    /// A voice was picked (nil = no secondary voice): back to the scheme.
    private func choose(_ e: VoiceEntry?, for role: VoiceRole) {
        switch role {
        case .main:
            guard let e = e else { return }
            draft.main = e
            // a secondary voice that no longer reads the other language does not fit any more
            if let s = draft.secondary, !VoiceRole.secondary(mainLanguage: e.lang).allows(s.lang) { draft.secondary = nil }
        case .secondary:
            draft.secondary = e
        }
        draft.secondaryGainDB = nil // the voices changed: measure again
        path.removeAll()
    }

    private func commit() {
        var s = withMeasuredGain(draft)
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.name.isEmpty { s.name = s.main.name }
        finished = true
        model.save(s)
        dismiss()
    }
}

/// Step 1: the language, common ones first.
private struct LanguageListView: View {
    @ObservedObject var model: AppModel
    let role: VoiceRole
    let selected: String?
    @Binding var path: [Route]
    let onChoose: (VoiceEntry?) -> Void

    var body: some View {
        let (common, others) = Languages.split(model.languages.filter(role.allows))
        List {
            if case .secondary = role {
                Section {
                    Button { onChoose(nil) } label: {
                        HStack {
                            Text("不使用副语音").foregroundColor(.primary)
                            Spacer()
                            if selected == nil { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                    .accessibilityAddTraits(selected == nil ? .isSelected : [])
                }
            }
            if !common.isEmpty {
                Section("常用") { ForEach(common, id: \.self, content: row) }
            }
            if !others.isEmpty {
                Section("其他语言") { ForEach(others, id: \.self, content: row) }
            }
        }
        .navigationTitle("选择\(role.title)的语言")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ code: String) -> some View {
        NavigationLink(value: Route.voices(role, code)) {
            Text(Languages.name(code)).foregroundColor(.primary)
        }
        .accessibilityAddTraits(code == selected ? .isSelected : [])
    }
}

/// Step 2: the voice. Picking one returns to the scheme; "试听" plays it.
private struct VoiceListView: View {
    @ObservedObject var model: AppModel
    let role: VoiceRole
    let language: String
    let selectedID: String?
    let onChoose: (VoiceEntry?) -> Void

    var body: some View {
        List {
            Section {
                ForEach(model.voices(language: language), id: \.id) { e in
                    HStack {
                        Button { onChoose(e) } label: {
                            HStack {
                                Text(e.name).foregroundColor(.primary)
                                Spacer()
                                if e.id == selectedID { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                        Button { model.sample(e) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(e.id == selectedID ? .isSelected : [])
                    .accessibilityAction { onChoose(e) }
                    .accessibilityAction(named: "试听") { model.sample(e) }
                }
            }
        }
        .navigationTitle(Languages.name(language))
        .navigationBarTitleDisplayMode(.inline)
    }
}
