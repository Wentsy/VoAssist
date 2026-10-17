import XCTest
@testable import BoostCore

final class NumbersTests: XCTestCase {
    private func zh(_ t: String, _ m: NumberReading = .values, _ lang: String = "zh-CN") -> String { Numbers.read(t, m, language: lang) }
    private func en(_ t: String, _ m: NumberReading = .values) -> String { Numbers.read(t, m, language: "en-US") }

    func testSystemLeavesEverythingToTheVoice() {
        for t in ["1234", "１０％", "2024年", "-5", "MP3"] {
            XCTAssertEqual(zh(t, .system), t)
            XCTAssertEqual(en(t, .system), t)
        }
    }

    func testChineseValues() {
        let cases = ["1234": "一千两百三十四", "0": "零", "7": "七", "10": "十", "12": "十二", "20": "二十", "110": "一百一十",
                     "1001": "一千零一", "1010": "一千零一十", "10010": "一万零一十", "100000": "十万", "120000": "十二万",
                     "22000": "两万两千", "220000": "二十二万", "100000001": "一亿零一", "200000000": "两亿",
                     "1000200000000": "一万亿零两亿", "2222": "两千两百二十二"]
        for (k, v) in cases { XCTAssertEqual(zh(k), v, k) }
        XCTAssertEqual(zh("2024年"), "两千零二十四年")
        XCTAssertEqual(zh("3.14 和 0.5"), "三点一四 和 零点五")
        XCTAssertEqual(zh("下载进度 50%，还剩 12.5％"), "下载进度 百分之五十，还剩 百分之十二点五")
        XCTAssertEqual(zh("气温 -5 度，(−3)"), "气温 负五 度，(负三)")
        XCTAssertEqual(zh("共 1,234,567 人"), "共 一百二十三万四千五百六十七 人")
        XCTAssertEqual(zh("Windows１０"), "Windows十")
        XCTAssertEqual(zh("iPhone 17 有 MP3"), "iPhone 十七 有 MP三")
    }

    func testChineseTwo() {
        XCTAssertEqual(zh("2个人，2本书，2小时"), "两个人，两本书，两小时")
        XCTAssertEqual(zh("第2个，2年级，2月，2"), "第二个，二年级，二月，二")
        XCTAssertEqual(zh("2万和2.5个"), "两万和二点五个")
    }

    func testChineseLeavesJoinedGroupsAndOddNumbers() {
        // times, dates, phone numbers, fractions and ranges: the voice reads them as values already
        for t in ["12:30", "2024-10-17", "138-0013-8000", "1/2", "1~2 天", "10-20%"] { XCTAssertEqual(zh(t), t) }
        XCTAssertEqual(zh("007 和 0571"), "零零七 和 零五七一")
        XCTAssertEqual(zh("12345678901234567"), "一二三四五六七八九零一二三四五六七")
        XCTAssertEqual(zh("192.168.1.1"), "一百九十二点一百六十八点一点一")
        XCTAssertEqual(zh("Wi-Fi-6 和 5-3"), "Wi-Fi-六 和 5-3", "a hyphen after a word is no minus sign")
        XCTAssertEqual(zh("1st"), "1st")
    }

    func testChineseDigits() {
        XCTAssertEqual(zh("1234", .digits), "一二三四")
        XCTAssertEqual(zh("2024年2个", .digits), "二零二四年二个")
        XCTAssertEqual(zh("3.14，50%，-5，1,234", .digits), "三点一四，百分之五零，负五，一二三四")
        XCTAssertEqual(zh("12:30 和 138-0013-8000", .digits), "一二:三零 和 一三八-零零一三-八零零零")
        XCTAssertEqual(zh("192.168.1.1", .digits), "一九二点一六八点一点一")
    }

    func testTraditionalChinese() {
        XCTAssertEqual(zh("1234", .values, "zh-TW"), "一千兩百三十四")
        XCTAssertEqual(zh("20000 和 3.5", .values, "yue-HK"), "兩萬 和 三點五")
        XCTAssertEqual(zh("2個", .values, "zh-TW"), "兩個")
        XCTAssertEqual(zh("-1.5", .digits, "zh-HK"), "負一點五")
    }

    func testEnglish() {
        XCTAssertEqual(en("1234"), "one thousand two hundred thirty-four")
        XCTAssertEqual(en("2024 and 1000000 and 0"), "two thousand twenty-four and one million and zero")
        XCTAssertEqual(en("115 and 1,000,021"), "one hundred fifteen and one million twenty-one")
        XCTAssertEqual(en("3.14, 50%, -5"), "three point one four, fifty percent, minus five")
        XCTAssertEqual(en("MP3 and x86"), "MP three and x eighty-six")
        XCTAssertEqual(en("12:30 on the 1st"), "12:30 on the 1st")
        XCTAssertEqual(en("1234", .digits), "one two three four")
        XCTAssertEqual(en("3.14 and 12:30", .digits), "three point one four and one two : three zero")
        XCTAssertEqual(en("2026年"), "two thousand twenty-six年")
    }

    func testOtherLanguagesOnlyKeepDigitsApart() {
        XCTAssertEqual(Numbers.read("1234円", .values, language: "ja-JP"), "1234円")
        XCTAssertEqual(Numbers.read("1234円", .digits, language: "ja-JP"), "1 2 3 4円")
    }

    func testSchemesReadNumbersTheirWay() throws {
        var s = VoiceScheme(name: "x", main: .tingting, secondary: .samantha)
        XCTAssertEqual(s.numbers, .system)
        let rules = RuleBook([ReadingRule(find: "(\\d+)%", replace: "百分比$1", regex: true)])
        XCTAssertEqual(s.prepared("50% 和 2个", rules: rules), "百分比50 和 2个")
        s.numbers = .values
        XCTAssertEqual(s.prepared("50% 和 2个", rules: rules), "百分比五十 和 两个", "the rules see the digits first")
        s.useRules = false
        XCTAssertEqual(BoostSynthesis.pieces("iPhone 17", scheme: s, rules: rules), [LanguageRun("iPhone ", .other), LanguageRun("十七", .main)])
        let plan = ApplePlanner.plan(VoiceOverRate.previewSSML("共 1234 人", percent: 50), scheme: s, rules: rules, map: .measured)
        XCTAssertTrue(plan.ssml.contains("共 一千两百三十四 人"), plan.ssml)

        // older schemes, and a reading a later version may add
        let old = #"{"main":{"id":"com.apple.voice.super-compact.zh-CN.Tingting","name":"婷婷","lang":"zh-CN"}}"#
        XCTAssertEqual(try JSONDecoder().decode(VoiceScheme.self, from: Data(old.utf8)).numbers, .system)
        let later = #"{"main":{"id":"com.apple.voice.super-compact.zh-CN.Tingting","name":"婷婷","lang":"zh-CN"},"numbers":"roman"}"#
        XCTAssertEqual(try JSONDecoder().decode(VoiceScheme.self, from: Data(later.utf8)).numbers, .system)
        s.numbers = .digits
        let back = try JSONDecoder().decode(VoiceScheme.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.numbers, .digits)
    }
}
