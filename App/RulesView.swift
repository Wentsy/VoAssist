import SwiftUI
import UIKit

private extension ReadingRule {
    /// One line for the list and for VoiceOver.
    var summary: String {
        let to = replace.isEmpty ? "（删除）" : replace
        return "\(find) → \(to)"
    }

    var flags: String {
        var f: [String] = []
        if regex { f.append("正则") }
        if ignoreCase { f.append("忽略大小写") }
        if wholeWord && !regex { f.append("整词") }
        return f.joined(separator: "、")
    }

    var problem: String? {
        if case .failure(let e) = compiled() { return e.message }
        return nil
    }
}

/// The rule list: switch on/off, reorder, edit, try them all, share.
struct RulesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: ReadingRule?
    @State private var isNew = false
    @State private var sample = "请重新连接 iOS 设备，进度 50%。"
    @State private var notice = ""

    /// The scheme the tests read with (the first Chinese one), with the rules switched on.
    private var testScheme: VoiceScheme? {
        guard var s = model.schemes.first(where: { LanguageRuns.isChinese($0.language) }) ?? model.schemes.first else { return nil }
        s.useRules = true
        return s
    }

    var body: some View {
        List {
            if !model.rules.isEmpty {
                Section("规则") {
                    ForEach(model.rules) { rule in
                        row(rule)
                    }
                    .onDelete { model.rules.remove(atOffsets: $0) }
                    .onMove { model.rules.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            Section("测试全部规则") {
                TextField("输入一段文字", text: $sample, axis: .vertical)
                if let s = testScheme {
                    Text(model.describe(sample, scheme: s)).font(.footnote).textSelection(.enabled)
                    Button("朗读结果") { model.preview(text: sample, scheme: s, voPercent: 50) }
                }
            }

            Section {
                Button("添加示例规则") {
                    model.addRules(ReadingRule.examples.map { var r = $0; r.id = UUID(); return r })
                    notice = "已添加 \(ReadingRule.examples.count) 条示例规则"
                }
                if !notice.isEmpty { Text(notice).font(.footnote) }
            }
        }
        .navigationTitle("朗读修正规则")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("添加") {
                    isNew = true
                    editing = ReadingRule(find: "", replace: "")
                }
            }
        }
        .sheet(item: $editing) { rule in
            NavigationStack {
                RuleEditView(model: model, rule: rule, isNew: isNew) { saved in
                    if let i = model.rules.firstIndex(where: { $0.id == saved.id }) {
                        model.rules[i] = saved
                    } else {
                        model.rules.append(saved)
                    }
                }
            }
        }
    }

    private func row(_ rule: ReadingRule) -> some View {
        HStack {
            Button {
                isNew = false
                editing = rule
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.summary).foregroundColor(rule.enabled ? .primary : .secondary)
                    let detail = [rule.flags, rule.note].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.secondary) }
                    if let p = rule.problem { Text(p).font(.caption).foregroundColor(.red) }
                }
            }
            Spacer()
            Toggle("启用", isOn: Binding(
                get: { rule.enabled },
                set: { on in if let i = model.rules.firstIndex(where: { $0.id == rule.id }) { model.rules[i].enabled = on } }))
            .labelsHidden()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rule.summary)，\(rule.enabled ? "已启用" : "已关闭")\(rule.flags.isEmpty ? "" : "，" + rule.flags)\(rule.note.isEmpty ? "" : "，" + rule.note)\(rule.problem.map { "，有错误：" + $0 } ?? "")")
        .accessibilityAction { isNew = false; editing = rule }
        .accessibilityAction(named: rule.enabled ? "关闭" : "启用") {
            if let i = model.rules.firstIndex(where: { $0.id == rule.id }) { model.rules[i].enabled.toggle() }
        }
        .accessibilityAction(named: "上移") { model.moveRule(rule.id, by: -1) }
        .accessibilityAction(named: "下移") { model.moveRule(rule.id, by: 1) }
        .accessibilityAction(named: "删除") { model.rules.removeAll { $0.id == rule.id } }
    }
}

/// One rule, with a live test of just this rule.
struct RuleEditView: View {
    @ObservedObject var model: AppModel
    @State var rule: ReadingRule
    let isNew: Bool
    let onSave: (ReadingRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sample = ""

    private var testScheme: VoiceScheme? {
        guard var s = model.schemes.first(where: { LanguageRuns.isChinese($0.language) }) ?? model.schemes.first else { return nil }
        s.useRules = true
        return s
    }

    var body: some View {
        Form {
            Section {
                TextField("查找", text: $rule.find)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("查找")
                TextField("替换为", text: $rule.replace)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("替换为")
                if let p = rule.problem { Text(p).foregroundColor(.red) }
            } header: {
                Text("查找与替换")
            }

            Section {
                Toggle("正则表达式", isOn: $rule.regex)
                Toggle("忽略大小写", isOn: $rule.ignoreCase)
                if !rule.regex {
                    Toggle("只匹配完整的英文单词", isOn: $rule.wholeWord)
                }
                Toggle("启用", isOn: $rule.enabled)
                TextField("备注", text: $rule.note)
            }

            Section("测试这条规则") {
                TextField("输入一段文字", text: $sample, axis: .vertical)
                if !sample.isEmpty {
                    let one: [ReadingRule] = { var r = rule; r.enabled = true; return [r] }()
                    Text("结果：\(RuleBook(one).apply(sample))").textSelection(.enabled)
                    if let s = testScheme {
                        Button("朗读结果") { model.preview(text: sample, scheme: s, voPercent: 50, rules: one) }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "新规则" : "编辑规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(rule)
                    dismiss()
                }
                .disabled(rule.find.isEmpty)
            }
        }
        .onAppear { if sample.isEmpty { sample = rule.regex ? "" : rule.find } }
    }
}
