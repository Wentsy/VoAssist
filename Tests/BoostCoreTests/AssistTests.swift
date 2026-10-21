import XCTest
@testable import BoostCore

final class LanguageRunsTests: XCTestCase {
    private func zh(_ t: String) -> [String] {
        LanguageRuns.split(t, mainLanguage: "zh-CN").map { "\($0.voice == .main ? "中" : "英"):\($0.text)" }
    }

    private func en(_ t: String) -> [String] {
        LanguageRuns.split(t, mainLanguage: "en-US").map { "\($0.voice == .main ? "EN" : "ZH"):\($0.text)" }
    }

    func testChineseVoiceHandsEnglishWordsOver() {
        XCTAssertEqual(zh("打开 Safari 浏览器"), ["中:打开 ", "英:Safari ", "中:浏览器"])
        XCTAssertEqual(zh("今天用 Speak Screen 读 hello world，效果不错。"),
                       ["中:今天用 ", "英:Speak Screen ", "中:读 ", "英:hello world，", "中:效果不错。"])
        XCTAssertEqual(zh("纯中文句子。"), ["中:纯中文句子。"])
        XCTAssertEqual(zh("Wi-Fi 和 don't"), ["英:Wi-Fi ", "中:和 ", "英:don't"])
    }

    func testAccentedWordsStayWholeFullWidthDigitsWithTheMainVoice() {
        XCTAssertEqual(zh("玩 Pokémon GO 去 café"), ["中:玩 ", "英:Pokémon GO ", "中:去 ", "英:café"])
        XCTAssertEqual(zh("Zürich 的 Re\u{301}sume\u{301}"), ["英:Zürich ", "中:的 ", "英:Re\u{301}sume\u{301}"])
        XCTAssertEqual(zh("Windows１０版本"), ["英:Windows", "中:１０版本"])
    }

    func testNumbersAlwaysStayWithTheMainVoice() {
        XCTAssertEqual(zh("iPhone 17 有 MP3"), ["英:iPhone ", "中:17 有 ", "英:MP", "中:3"])
        XCTAssertEqual(zh("2026年10月"), ["中:2026年10月"])
        XCTAssertEqual(zh("Tel13800138000"), ["英:Tel", "中:13800138000"])
        XCTAssertEqual(zh("Call 138-0013-8000"), ["英:Call ", "中:138-0013-8000"])
    }

    /// Symbols are read by the main voice; pause punctuation only makes a pause; the dot inside a word is read out.
    func testSymbolsStayWithTheMainVoice() {
        XCTAssertEqual(zh("Node.js"), ["英:Node", "中:.", "英:js"])
        XCTAssertEqual(zh("user@example.com"), ["英:user", "中:@", "英:example", "中:.", "英:com"])
        XCTAssertEqual(zh("C# 和 AT&T"), ["英:C", "中:# 和 ", "英:AT", "中:&", "英:T"])
        XCTAssertEqual(zh("@张三"), ["中:@张三"])
        XCTAssertEqual(zh("@user"), ["中:@", "英:user"])
        XCTAssertEqual(zh("Hello. 你好"), ["英:Hello. ", "中:你好"])
        XCTAssertEqual(zh("打开 Safari，然后"), ["中:打开 ", "英:Safari，", "中:然后"])
        XCTAssertEqual(zh("https://www.apple.com"), ["英:https", "中:://", "英:www", "中:.", "英:apple", "中:.", "英:com"])
    }

    func testEnglishVoiceHandsChineseOver() {
        XCTAssertEqual(en("Open 微信 now"), ["EN:Open ", "ZH:微信 ", "EN:now"])
        XCTAssertEqual(en("Released in 2026年10月, ok"), ["EN:Released in 2026", "ZH:年", "EN:10", "ZH:月, ", "EN:ok"])
        XCTAssertEqual(en("No Chinese here."), ["EN:No Chinese here."])
    }

    func testPunctuationOnlyGluesToNeighbour() {
        XCTAssertEqual(zh("“Hello”"), ["英:“Hello”"])
        XCTAssertEqual(zh("……"), ["中:……"])
    }

    func testCantoneseIsChinese() {
        XCTAssertTrue(LanguageRuns.isChinese("yue-HK"))
        XCTAssertTrue(VoiceScheme.secondaryReadsEnglish(main: "yue-HK"))
        XCTAssertEqual(LanguageRuns.split("打开 Safari", mainLanguage: "yue-HK"), [LanguageRun("打开 ", .main), LanguageRun("Safari", .other)])
    }

    func testJapaneseIsLeftAlone() {
        XCTAssertEqual(LanguageRuns.split("日本語のテキスト abc", mainLanguage: "ja-JP"), [LanguageRun("日本語のテキスト abc", .main)])
    }
}

final class RulesTests: XCTestCase {
    func testPlainReplacementAndOrder() {
        let book = RuleBook([
            ReadingRule(find: "重新", replace: "虫新"),
            ReadingRule(find: "虫新", replace: "从新"), // runs on the result of the rule before
            ReadingRule(find: "关闭", replace: "关掉", enabled: false),
        ])
        XCTAssertEqual(book.apply("请重新关闭"), "请从新关闭")
    }

    func testPlainTextIsLiteral() {
        let book = RuleBook([ReadingRule(find: "a.b", replace: "$1")])
        XCTAssertEqual(book.apply("a.b axb"), "$1 axb")
    }

    func testWholeWordAndCase() {
        let book = RuleBook([ReadingRule(find: "live", replace: "lyve", ignoreCase: true, wholeWord: true)])
        XCTAssertEqual(book.apply("Live deliver 我live了 lively"), "lyve deliver 我lyve了 lively")
        let strict = RuleBook([ReadingRule(find: "US", replace: "U S")])
        XCTAssertEqual(strict.apply("US us"), "U S us")
    }

    func testRegexWithGroups() {
        let book = RuleBook([ReadingRule(find: "(\\d+(?:\\.\\d+)?)%", replace: "百分之$1", regex: true)])
        XCTAssertEqual(book.apply("电量 50%，进度 12.5%"), "电量 百分之50，进度 百分之12.5")
    }

    func testExamplesAreValidAndDoWhatTheySay() {
        for r in ReadingRule.examples {
            if case .failure(let e) = r.compiled() { XCTFail("\(r.find): \(e.message)") }
        }
        let on = ReadingRule.examples.map { var r = $0; r.enabled = true; return r }
        XCTAssertEqual(RuleBook(on).apply("电话13812345678，iOS 更新完成 50%★"), "电话138 1234 5678，eye O S 更新完成 百分之50")
    }

    func testBrokenRegexIsSkipped() {
        let bad = ReadingRule(find: "(abc", replace: "x", regex: true)
        XCTAssertEqual(bad.compiled().failureMessage, ReadingRule.RuleError.badPattern.message)
        XCTAssertEqual(RuleBook([bad, ReadingRule(find: "abc", replace: "d")]).apply("(abc"), "(d")
    }

    func testPiecesFollowTheScheme() {
        var scheme = VoiceScheme(name: "婷婷", main: .tingting, secondary: .samantha)
        let rules = RuleBook([ReadingRule(find: "微信", replace: "WeChat")])
        XCTAssertEqual(BoostSynthesis.pieces("打开微信", scheme: scheme, rules: rules),
                       [LanguageRun("打开", .main), LanguageRun("WeChat", .other)])
        scheme.useRules = false
        scheme.secondary = nil
        XCTAssertEqual(BoostSynthesis.pieces("打开微信", scheme: scheme, rules: rules), [LanguageRun("打开微信", .main)])
        XCTAssertEqual(BoostSynthesis.pieces("。，", scheme: scheme, rules: rules), [])
        var english = VoiceScheme(name: "S", main: .samantha, secondary: .tingting)
        XCTAssertEqual(BoostSynthesis.pieces("Open 微信", scheme: english, rules: rules), [LanguageRun("Open WeChat", .main)])
        english.useRules = false
        XCTAssertEqual(BoostSynthesis.pieces("Open 微信", scheme: english, rules: rules),
                       [LanguageRun("Open ", .main), LanguageRun("微信", .other)], "rules only where the scheme uses them")
    }
}

final class SchemeTests: XCTestCase {
    func testProviderIdentifiersRoundTrip() {
        let s = VoiceScheme.defaultTingting
        XCTAssertEqual(VoiceScheme.schemeID(fromProvider: s.providerIdentifier), s.id)
        XCTAssertNil(VoiceScheme.schemeID(fromProvider: "com.zdyi.voassist.v.com.apple.voice.compact.zh-CN.Tingting"))
        XCTAssertEqual(VoiceScheme.defaults.map(\.name), ["婷婷+Samantha"])
        XCTAssertEqual(VoiceScheme.defaults.map(\.language), ["zh-CN"])
        XCTAssertEqual(VoiceScheme.defaults.first?.secondary, .samantha)
    }

    /// A Chinese scheme in every Chinese list, its own first; any other in its own alone.
    func testOfferedLanguages() {
        XCTAssertEqual(VoiceScheme.defaultTingting.offeredLanguages, ["zh-CN", "zh-TW", "yue-HK"])
        XCTAssertEqual(VoiceScheme(name: "善怡", main: .sinji, secondary: .samantha).offeredLanguages, ["yue-HK", "zh-CN", "zh-TW"])
        XCTAssertEqual(VoiceScheme(name: "Samantha", main: .samantha, secondary: .tingting).offeredLanguages, ["en-US"])
        // one voice per language: the scheme's own keeps its identifier, the others lead back to it
        let s = VoiceScheme.defaultTingting
        XCTAssertEqual(s.providerIdentifier(for: "zh-CN"), s.providerIdentifier)
        XCTAssertEqual(s.providerIdentifier(for: "yue-HK"), s.providerIdentifier + ".yue-HK")
        for lang in s.offeredLanguages { XCTAssertEqual(VoiceScheme.schemeID(fromProvider: s.providerIdentifier(for: lang)), s.id) }
    }

    func testDecodingFillsDefaultsAndClamps() throws {
        let json = #"{"main":{"id":"com.apple.voice.compact.zh-CN.Tingting","name":"婷婷","lang":"zh-CN"},"boost":9}"#
        let s = try JSONDecoder().decode(VoiceScheme.self, from: Data(json.utf8)).clamped()
        XCTAssertEqual(s.name, "婷婷")
        XCTAssertNil(s.secondary)
        XCTAssertEqual(s.boost, 6)
        XCTAssertTrue(s.balanceVolume)
        XCTAssertTrue(s.useRules)
    }

    func testOnlyAppleSecondaryVoicesAndUnreadableEntriesAreSkipped() throws {
        let ours = VoiceEntry(id: VoiceScheme.defaultTingting.providerIdentifier, name: "婷婷+Samantha", lang: "en-US")
        XCTAssertNil(VoiceScheme(name: "x", main: .tingting, secondary: ours).clamped().secondary)
        XCTAssertEqual(VoiceScheme(name: "x", main: .tingting, secondary: .samantha).clamped().secondary, .samantha)

        let text = #"{"format":"voassist","schemes":[{"main":{"id":"com.apple.voice.super-compact.zh-CN.Tingting","lang":"zh-CN"}},"#
            + #"{"main":"broken"}],"rules":[{"find":"甲"},{"replace":"no find"}]}"#
        let b = try XCTUnwrap(ShareBundle.parse(text))
        XCTAssertEqual(b.schemes?.map(\.main.name), ["Tingting"], "a voice without a name is named after its identifier")
        XCTAssertEqual(b.rules?.map(\.find), ["甲"])
    }

    func testSecondaryGain() {
        var s = VoiceScheme(name: "x", main: .tingting, secondary: .samantha)
        XCTAssertTrue(s.balanceVolume, "on by default")
        XCTAssertEqual(s.secondaryGain, 1, "not measured yet")
        s.secondaryGainDB = 6
        s.balanceVolume = false
        XCTAssertEqual(s.secondaryGain, 1, "turned off")
        s.balanceVolume = true
        XCTAssertEqual(s.secondaryGain, Float(pow(10, 6.0 / 20)), accuracy: 1e-5)
        s.secondaryGainDB = 40
        XCTAssertEqual(s.secondaryGain, Float(pow(10, 12.0 / 20)), accuracy: 1e-5, "limited to 12 dB")
        XCTAssertEqual(Loudness.balanceDB(main: -20, secondary: -26), 6)
        XCTAssertEqual(Loudness.balanceDB(main: -20, secondary: -50), 12)
    }

    func testLoudnessIgnoresSilence() {
        let tone = (0..<22050).map { 0.1 * sin(2 * Float.pi * 200 * Float($0) / 22050) }
        let a = Loudness.level(tone, sampleRate: 22050)!
        let b = Loudness.level(tone + [Float](repeating: 0, count: 44100), sampleRate: 22050)!
        XCTAssertEqual(a, 10 * log10(0.005), accuracy: 0.1)
        XCTAssertEqual(a, b, accuracy: 0.01, "pauses do not lower the level")
    }

    func testShareRoundTripAndMerge() {
        var mine = VoiceScheme.defaultTingting
        mine.boost = 2
        let rules = ReadingRule.examples
        let text = ShareBundle(schemes: [mine], rules: rules).text()
        guard let back = ShareBundle.parse(text) else { return XCTFail("not parsed") }
        XCTAssertEqual(back.schemes?.first?.boost, 2)
        XCTAssertEqual(back.rules?.map(\.find), rules.map(\.find))

        let m = back.merged(into: [mine], rules: rules)
        XCTAssertEqual(m.addedSchemes, 1)
        XCTAssertEqual(m.schemes.last?.name, "婷婷+Samantha（2）", "same name in the same language")
        XCTAssertNotEqual(m.schemes.last?.id, mine.id, "imported schemes are new ones")
        XCTAssertEqual(m.addedRules, 0)
        XCTAssertEqual(m.skippedRules, rules.count, "identical rules are not added twice")
        let again = back.merged(into: m.schemes, rules: [])
        XCTAssertEqual(again.schemes.last?.name, "婷婷+Samantha（3）")
        XCTAssertEqual(again.addedRules, rules.count)
    }

    func testParseAcceptsBareRuleListsAndRejectsOtherText() {
        XCTAssertEqual(ShareBundle.parse(#"[{"find":"甲","replace":"乙"}]"#)?.rules?.first?.replace, "乙")
        XCTAssertNil(ShareBundle.parse("not json"))
        XCTAssertEqual(ShareBundle.parse(#"{"format":"voassist","rules":[{"find":"甲","replace":"乙"}]}"#)?.rules?.count, 1,
                       "version may be left out")
        XCTAssertNil(ShareBundle.parse(#"{"hello":1}"#))
    }
}

private extension Result where Failure == ReadingRule.RuleError {
    var failureMessage: String? {
        if case .failure(let e) = self { return e.message }
        return nil
    }
}

final class ApplePlanTests: XCTestCase {
    private let map = RateMap.measured
    private let tt = VoiceScheme(name: "婷婷", main: .tingting, secondary: .samantha)

    func testPausesAndStructureAreLeftToTheVoiceRateIsConverted() {
        let vo = #"<?xml version="1.0"?><speak xml:lang="zh-CN"><prosody rate="129.99994%" pitch="+2st">设置<break time="500ms"/>按钮</prosody></speak>"#
        let p = ApplePlanner.plan(vo, scheme: tt, rules: RuleBook([]), map: map)
        // VoiceOver's rate is the speed itself (55 % sends 130 %): passed on as it is
        XCTAssertEqual(p.ssml, #"<speak><prosody rate="130%" pitch="+2st">设置<break time="500ms"/>按钮</prosody></speak>"#)
        XCTAssertEqual(p.speed, 1.3, accuracy: 0.001)
        // capped at what the system voice can do (VoiceOver 100 % sends 400 %)
        XCTAssertEqual(ApplePlanner.plan(#"<speak><prosody rate="500%">快</prosody></speak>"#, scheme: tt, rules: RuleBook([]), map: map).speed, 4.044, accuracy: 0.001)
        XCTAssertEqual(p.segments, [.main])
        XCTAssertFalse(p.keepLeading)
        XCTAssertFalse(p.keepTrailing)
        XCTAssertTrue(p.hasText)
    }

    func testOtherLanguageGoesToTheSecondaryVoiceInPlace() {
        let p = ApplePlanner.plan("<speak>打开 Safari 浏览器，Hello.</speak>", scheme: tt, rules: RuleBook([]), map: map)
        let sam = #"<voice name="com.apple.voice.super-compact.en-US.Samantha">"#
        XCTAssertEqual(p.ssml, "<speak>打开 \(sam)Safari </voice>浏览器，\(sam)Hello.</voice></speak>")
        XCTAssertEqual(p.segments, [.main, .other, .main, .other])
        // a switch without punctuation adds no pause to the voices' own soft ends; after "，" the main voice's own pause
        XCTAssertEqual(p.switchCapMs, [0, 0, 300])
        // a pause, when one is set, gets shorter as the voice speaks faster (VoiceOver 100 % = about 4x)
        ApplePlanner.switchPauseMs = 15
        defer { ApplePlanner.switchPauseMs = 0 }
        let fast = ApplePlanner.plan(#"<speak><prosody rate="400%">打开 Safari 浏览器</prosody></speak>"#, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(fast.switchCapMs, [4, 4])
    }

    /// VoiceOver's pause where the voices switch stays: "App Store", a break, then the hint; "Safari" / "按钮".
    func testVoiceOverPauseAtASwitchIsKept() {
        let hint = ApplePlanner.plan(#"<speak><s>App Store</s><s><break time="800ms"/></s><s>轻点两下以打开</s></speak>"#,
                                     scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(hint.segments, [.other, .main])
        XCTAssertEqual(hint.switchCapMs, [nil])
        let trait = ApplePlanner.plan("<speak><s>Safari</s><s>按钮</s></speak>", scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(trait.switchCapMs, [nil])
        // inside a sentence the voices still join closely
        let joined = ApplePlanner.plan("<speak><s>打开 Safari 浏览器</s></speak>", scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(joined.switchCapMs, [0, 0])
    }

    func testCutAfterPunctuation() {
        XCTAssertEqual(ApplePlanner.cut("今天天气很好。我们去公园，好吗？", at: .none), ["今天天气很好。我们去公园，好吗？"])
        XCTAssertEqual(ApplePlanner.cut("今天天气很好。我们去公园，好吗？", at: .sentence), ["今天天气很好。", "我们去公园，好吗？"])
        // a part too short to stand alone stays with what follows; nothing is cut off at the end
        XCTAssertEqual(ApplePlanner.cut("今天天气很好。我们去公园，好吗？", at: .clause), ["今天天气很好。", "我们去公园，", "好吗？"])
        XCTAssertEqual(ApplePlanner.cut("好的，我们走吧。", at: .clause), ["好的，我们走吧。"])
        // closing quotes go with their part; the 、 of a list is no cut
        XCTAssertEqual(ApplePlanner.cut("他说：“我来了。”然后坐下", at: .sentence), ["他说：“我来了。”", "然后坐下"])
        XCTAssertEqual(ApplePlanner.cut("苹果、香蕉、橘子都有", at: .clause), ["苹果、香蕉、橘子都有"])
        // a Western mark only before white space
        XCTAssertEqual(ApplePlanner.cut("Version 3.5 of Node.js is out. Get it, now", at: .clause),
                       ["Version 3.5 of Node.js is out. ", "Get it, ", "now"])
    }

    func testPiecesCutAfterPunctuationPauseAsTheMarkAsks() {
        let ssml = #"<speak><prosody rate="200%">打开设置页面，再找到 Safari 浏览器窗口。然后轻点两下</prosody></speak>"#
        let whole = ApplePlanner.plan(ssml, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(whole.pieces.map(\.text), ["打开设置页面，再找到 ", "Safari ", "浏览器窗口。然后轻点两下"])
        XCTAssertEqual(whole.pieceCapMs, whole.switchCapMs)
        let cut = ApplePlanner.plan(ssml, scheme: tt, rules: RuleBook([]), map: map, cutAt: .clause)
        XCTAssertEqual(cut.ssml, whole.ssml)
        XCTAssertEqual(cut.segments, whole.segments)
        XCTAssertEqual(cut.pieces.map(\.text), ["打开设置页面，", "再找到 ", "Safari ", "浏览器窗口。", "然后轻点两下"])
        XCTAssertEqual(cut.pieces.map(\.voice), [.main, .main, .other, .main, .main])
        // the clause and sentence marks' pauses at half the time at twice the speed, the switches as before
        XCTAssertEqual(cut.pieceCapMs, [150, 0, 0, 120])
        // each piece a whole SSML of its own
        XCTAssertEqual(cut.pieces[1].ssml, #"<speak><prosody rate="200%">再找到 </prosody></speak>"#)
    }

    func testLoneCapitalIsReadAsTheLetter() {
        let sam = #"<voice name="com.apple.voice.super-compact.en-US.Samantha">"#
        // left alone by the split: lower-cased, so not "capital C"
        XCTAssertEqual(ApplePlanner.plan("<speak>学 C 语言</speak>", scheme: tt, rules: RuleBook([]), map: map).ssml,
                       "<speak>学 \(sam)c </voice>语言</speak>")
        // in a stretch of words, or the whole request (VoiceOver moving by character): as it is
        XCTAssertEqual(ApplePlanner.plan("<speak>Plan B 不错</speak>", scheme: tt, rules: RuleBook([]), map: map).ssml,
                       "<speak>\(sam)Plan B </voice>不错</speak>")
        XCTAssertEqual(ApplePlanner.plan("<speak>C</speak>", scheme: tt, rules: RuleBook([]), map: map).ssml,
                       "<speak>\(sam)C</voice></speak>")
    }

    func testSymbolReadOutGetsNoFullStopPause() {
        // "Node.js": the dot is read by the main voice and is no full stop, so no pause after it
        let p = ApplePlanner.plan("<speak>Node.js 和 Hello. 你好</speak>", scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.segments, [.other, .main, .other, .main, .other, .main])
        XCTAssertEqual(p.switchCapMs, [0, 0, 0, 0, 240])
    }

    /// Where the voices switch after a punctuation mark: the pause the main voice makes there, shorter as it speaks faster.
    func testPunctuationPauseAtASwitch() {
        XCTAssertEqual(ApplePlanner.switchPause(after: "设置，", speed: 1), 300)
        XCTAssertEqual(ApplePlanner.switchPause(after: "Wi-Fi、", speed: 1), 300)
        XCTAssertEqual(ApplePlanner.switchPause(after: "下载完成。", speed: 1), 240)
        XCTAssertEqual(ApplePlanner.switchPause(after: "Hello, ", speed: 2), 150)
        XCTAssertEqual(ApplePlanner.switchPause(after: "打开", speed: 1), 0)
        XCTAssertEqual(ApplePlanner.switchPause(after: ".", speed: 1), 0, "a dot read out is no full stop")
        let fast = ApplePlanner.plan(#"<speak><prosody rate="400%">设置，Safari</prosody></speak>"#, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(fast.switchCapMs, [75])
    }

    /// The request cut where the voices switch, each piece a whole SSML for one voice.
    func testPiecesPerVoice() {
        let p = ApplePlanner.plan("<speak>打开 Safari 浏览器，Hello.</speak>", scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.pieces.map(\.voice), [.main, .other, .main, .other])
        XCTAssertEqual(p.pieces.map(\.ssml), ["<speak>打开 </speak>", "<speak>Safari </speak>", "<speak>浏览器，</speak>", "<speak>Hello.</speak>"])
        XCTAssertEqual(p.pieces.map(\.text), ["打开 ", "Safari ", "浏览器，", "Hello."])
        XCTAssertEqual(p.pieces.map(\.voice), p.segments)
        XCTAssertEqual(p.switchCapMs.count, p.pieces.count - 1)
    }

    /// VoiceOver's elements open at a cut close at its end and open again in the next piece; its break goes with the
    /// voice before; its language tags go.
    func testPiecesKeepTheElements() {
        let ssml = #"<speak><prosody rate="200%" volume="-6dB"><s><lang xml:lang="en-US">App Store</lang></s><s><break time="800ms"/></s><s>轻点两下以打开</s></prosody></speak>"#
        let p = ApplePlanner.plan(ssml, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.pieces.map(\.ssml), [
            #"<speak><prosody rate="200%" volume="-6dB"><s>App Store</s><s><break time="800ms"/></s><s></s></prosody></speak>"#,
            #"<speak><prosody rate="200%" volume="-6dB"><s>轻点两下以打开</s></prosody></speak>"#,
        ])
        XCTAssertEqual(p.pieces.map(\.speed), [2, 2])
        XCTAssertEqual(p.switchCapMs, [nil], "VoiceOver's own pause at the switch")
    }

    func testPiecesSecondaryRateAndSinglePiece() {
        var s = tt
        s.secondaryRate = 0.5
        let p = ApplePlanner.plan(#"<speak><prosody rate="100%">读 Hello</prosody></speak>"#, scheme: s, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.pieces.last?.ssml, #"<speak><prosody rate="100%"><prosody rate="50%">Hello</prosody></prosody></speak>"#)
        XCTAssertEqual(p.pieces.last?.speed, 0.5)
        // one voice: one piece, the request as rewritten
        let one = ApplePlanner.plan(#"<speak><prosody rate="150%">设置<break time="250ms"/>按钮</prosody></speak>"#, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(one.pieces.map(\.ssml), [one.ssml])
        // breaks only: one piece for the main voice
        let gap = ApplePlanner.plan(#"<speak><break time="500ms"/></speak>"#, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(gap.pieces.map(\.voice), [.main])
        XCTAssertEqual(gap.pieces.first?.ssml, gap.ssml)
    }

    /// As VoiceOver on iOS 27 sends an item (captured on an iPhone Air): one request, its parts in <s>, each in <lang>.
    func testPiecesOfARealRequest() {
        let ssml = #"<speak><prosody rate="99.99998%" volume="-1.9382001dB"><s><lang xml:lang="cmn-CN">打开Safari浏览器</lang></s><s><lang xml:lang="cmn-CN">按钮</lang></s></prosody></speak>"#
        let p = ApplePlanner.plan(ssml, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.pieces.map(\.ssml), [
            #"<speak><prosody rate="100%" volume="-1.9382001dB"><s>打开</s></prosody></speak>"#,
            #"<speak><prosody rate="100%" volume="-1.9382001dB"><s>Safari</s></prosody></speak>"#,
            #"<speak><prosody rate="100%" volume="-1.9382001dB"><s>浏览器</s><s>按钮</s></prosody></speak>"#,
        ])
        XCTAssertEqual(p.switchCapMs, [0, 0])
    }

    /// Every piece is well-formed for the system voice.
    func testPiecesAreWellFormed() {
        let requests = [
            #"<speak><prosody rate="250%"><s>设置</s><s>按钮</s></prosody></speak>"#,
            #"<speak><prosody rate="130%" pitch="-15%"><s>打开 Wi-Fi 和 Bluetooth</s><s>按钮</s><s><break time="800ms"/></s><s>轻点两下以打开 Safari 浏览器</s></prosody></speak>"#,
            #"<speak><lang xml:lang="cmn"><prosody volume="-1.9382001dB">听见时光beta版，<say-as interpret-as="characters">AB</say-as>中</prosody></lang></speak>"#,
            "打开 App Store 有更新",
        ]
        for r in requests {
            let p = ApplePlanner.plan(r, scheme: tt, rules: RuleBook([]), map: map)
            XCTAssertFalse(p.pieces.isEmpty, r)
            for piece in p.pieces {
                XCTAssertTrue(XMLParser(data: Data(piece.ssml.utf8)).parse(), "\(piece.ssml) from \(r)")
                XCTAssertFalse(piece.ssml.contains("<voice"), piece.ssml)
            }
        }
    }

    /// Samantha passes over Chinese marks: in her stretches they become hers.
    func testChineseMarksForTheWesternVoice() {
        XCTAssertEqual(LanguageRuns.westernPunctuation("Hello，World、OK"), "Hello, World, OK")
        XCTAssertEqual(LanguageRuns.westernPunctuation("Hello"), "Hello")
        let sam = #"<voice name="com.apple.voice.super-compact.en-US.Samantha">"#
        XCTAssertEqual(ApplePlanner.plan("<speak>Hello，World 你好，世界</speak>", scheme: tt, rules: RuleBook([]), map: map).ssml,
                       "<speak>\(sam)Hello, World </voice>你好，世界</speak>")
    }

    func testSecondaryRelativeRateIsAbsoluteInside() {
        var s = tt
        s.secondaryRate = 0.5
        let p = ApplePlanner.plan(#"<speak><prosody rate="100%">读 Hello</prosody></speak>"#, scheme: s, rules: RuleBook([]), map: map)
        XCTAssertTrue(p.ssml.contains(#"<prosody rate="50%">Hello</prosody>"#), p.ssml) // 0.5 x the main voice's 1x
    }

    func testRulesTextOnlyAndEscaping() {
        let rules = RuleBook([ReadingRule(find: "50%", replace: "百分之50"), ReadingRule(find: "<", replace: "小于")])
        let p = ApplePlanner.plan(#"<speak>进度 50% &lt; 60%<break strength="weak"/></speak>"#, scheme: tt, rules: rules, map: map)
        XCTAssertEqual(p.ssml, #"<speak>进度 百分之50 小于 60%<break strength="weak"/></speak>"#)
        XCTAssertTrue(p.keepTrailing, "VoiceOver's own pause at the end stays")
    }

    func testLanguageAndVoiceTagsAreDroppedWhitespaceTextToo() {
        let p = ApplePlanner.plan("<speak>\n  <s xml:lang=\"en-US\"><lang xml:lang=\"en-US\">中文</lang></s>\n</speak>", scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.ssml, "<speak><s>中文</s></speak>")
    }

    func testSpaceBetweenInlineElementsAndNumericEntities() {
        let one = VoiceScheme(name: "婷婷", main: .tingting, secondary: nil)
        let p = ApplePlanner.plan(#"<speak><prosody pitch="+5%">你好</prosody> <prosody pitch="-5%">世界&#8217;s</prosody> </speak>"#,
                                  scheme: one, rules: RuleBook([]), map: map)
        XCTAssertEqual(p.ssml, #"<speak><prosody pitch="+5%">你好</prosody><prosody pitch="-5%"> 世界’s</prosody></speak>"#,
                       "the words stay apart; no space after the last text")
    }

    func testNonFiniteNumbersDoNotCrash() {
        let p = ApplePlanner.plan(#"<speak><prosody rate="nan%">你好<break time="infms"/></prosody></speak>"#,
                                  scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertTrue(p.ssml.contains(#"rate="100%""#))
        XCTAssertEqual(SSML.breakMs(#"time="1e30ms""#), 2000)
        XCTAssertFalse(ApplePlanner.rebuild(SSML.parse(#"<speak><prosody rate="inf">a</prosody></speak>"#)).isEmpty)
    }

    func testBreakOnlySpacer() {
        let p = ApplePlanner.plan(#"<speak><break time="300ms"/></speak>"#, scheme: tt, rules: RuleBook([]), map: map)
        XCTAssertFalse(p.hasText)
        XCTAssertTrue(p.keepLeading && p.keepTrailing)
        XCTAssertEqual(p.segments, [])
    }

    func testPlainTextAndPreview() {
        XCTAssertEqual(ApplePlanner.plan("你好", scheme: tt, rules: RuleBook([]), map: map).ssml, "<speak>你好</speak>")
        let preview = VoiceOverRate.previewSSML("A&B", percent: 100)
        XCTAssertEqual(preview, #"<speak><prosody rate="400%">A&amp;B</prosody></speak>"#)
    }

    func testRebuildFromParsedRequest() {
        let p = SSML.parse(#"<speak><prosody rate="150%">设置<break time="250ms"/>按钮</prosody></speak>"#)
        XCTAssertEqual(ApplePlanner.rebuild(p), #"<speak><prosody rate="150%">设置<break time="250ms"/>按钮</prosody></speak>"#)
    }
}

final class SharedFileTests: XCTestCase {
    /// After a restart the shared files are there but closed until the first unlock (data protection), and VoiceOver
    /// reads the lock screen meanwhile: what the extension got then must not stick once they open (the boost was lost
    /// until the scheme was changed).
    func testFilesClosedUntilTheFirstUnlockAreReadOnceTheyOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SharedStore.testContainer = dir
        defer {
            SharedStore.testContainer = nil
            try? FileManager.default.removeItem(at: dir)
        }
        var s = VoiceScheme.defaultTingting
        s.boost = 4.5
        XCTAssertTrue(VoiceScheme.save([s]))
        XCTAssertTrue(RuleBook.save([ReadingRule(find: "甲", replace: "乙")]))
        let files = ["schemes.json", "rules.json"].map { dir.appendingPathComponent($0).path }

        for f in files { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f) }
        XCTAssertEqual(VoiceScheme.shared().first?.boost, 1, "the defaults while closed")
        XCTAssertEqual(RuleBook.shared().apply("甲"), "甲")

        for f in files { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f) }
        XCTAssertEqual(VoiceScheme.shared().first?.boost, 4.5, "read once open, though the file did not change")
        XCTAssertEqual(RuleBook.shared().apply("甲"), "乙")
    }
}

final class DiagnosticLogTests: XCTestCase {
    private var dir: URL!
    private var savedDirectory: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SharedStore.testContainer = dir
        savedDirectory = DiagnosticLog.directory
        DiagnosticLog.directory = dir.appendingPathComponent("Diagnostics")
    }

    override func tearDown() {
        SharedStore.testContainer = nil
        DiagnosticLog.directory = savedDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    private func setLog(until: Date?, speech: Bool = false) {
        var s = BoostSettings()
        s.logUntil = until
        s.logSpeech = speech
        XCTAssertTrue(BoostSettings.save(s))
        // a new modification date for the settings cache, even within the file system's time resolution
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 1...1000))],
                                               ofItemAtPath: dir.appendingPathComponent("settings.json").path)
    }

    func testOnlyWhileSwitchedOnAndForAnHourAtMost() {
        DiagnosticLog.write("before")
        XCTAssertEqual(DiagnosticLog.contents(), "", "off by default")
        setLog(until: Date().addingTimeInterval(DiagnosticLog.duration))
        XCTAssertTrue(DiagnosticLog.isOn)
        DiagnosticLog.write("one")
        DiagnosticLog.write("two")
        let lines = DiagnosticLog.contents().split(separator: "\n")
        XCTAssertTrue(lines.last?.hasSuffix("] two") == true)
        XCTAssertTrue(lines.dropLast().last?.hasSuffix("] one") == true)
        setLog(until: Date().addingTimeInterval(-1))
        XCTAssertFalse(DiagnosticLog.isOn, "expired")
        DiagnosticLog.write("three")
        XCTAssertFalse(DiagnosticLog.contents().contains("three"))
        DiagnosticLog.clear()
        XCTAssertEqual(DiagnosticLog.contents(), "")
    }

    func testSpeechOnlyWhenAskedFor() {
        setLog(until: Date().addingTimeInterval(60))
        XCTAssertEqual(DiagnosticLog.speech("打开 Safari"), "9 chars")
        setLog(until: Date().addingTimeInterval(60), speech: true)
        XCTAssertEqual(DiagnosticLog.speech("打开 Safari"), "\"打开 Safari\"")
        XCTAssertEqual(DiagnosticLog.speech(String(repeating: "长", count: 300)).count, DiagnosticLog.maxSpeech + 3)
    }

    func testKeepsTwoFilesUnderTheLimit() {
        setLog(until: Date().addingTimeInterval(60))
        let line = String(repeating: "x", count: 10_000)
        for i in 0..<250 { DiagnosticLog.write("\(i) \(line)") }
        let all = DiagnosticLog.contents()
        XCTAssertLessThan(all.utf8.count, 2 * DiagnosticLog.maxBytes + 20_000)
        XCTAssertFalse(all.contains("] 0 x"), "the oldest are gone")
        XCTAssertTrue(all.contains("] 249 x"))
    }

    func testSettingsWithoutTheLogFields() throws {
        let s = try JSONDecoder().decode(BoostSettings.self, from: Data("{}".utf8))
        XCTAssertNil(s.logUntil)
        XCTAssertFalse(s.logSpeech)
        XCTAssertFalse(s.isLogging())
    }
}

