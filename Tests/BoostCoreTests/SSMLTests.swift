import XCTest
@testable import BoostCore

final class SSMLTests: XCTestCase {
    func testProsodyAndBreaks() {
        let s = """
        <speak><prosody rate="150%" pitch="+2st" volume="-6dB">设置<break time="250ms"/>按钮<break strength="weak"/>轻点两下以打开</prosody></speak>
        """
        let p = SSML.parse(s)
        XCTAssertEqual(p.rate, 1.5, accuracy: 1e-9)
        XCTAssertEqual(Double(p.pitch), pow(2, 2.0 / 12), accuracy: 1e-4)
        XCTAssertEqual(Double(p.volume), 0.501, accuracy: 0.01)
        XCTAssertEqual(p.segments, [
            Segment(text: "设置", silenceMs: 250, explicitBreak: true),
            Segment(text: "按钮", silenceMs: 200, explicitBreak: true),
            Segment(text: "轻点两下以打开", silenceMs: 0),
        ])
    }

    func testBreakOnlyRequest() {
        let p = SSML.parse("<speak><break time=\"500ms\"/></speak>")
        XCTAssertEqual(p.segments, [Segment(text: "", silenceMs: 500, explicitBreak: true)])
    }

    func testSentencesAndEntities() {
        let p = SSML.parse("<speak><s>A &amp; B</s><s>第二句</s></speak>")
        XCTAssertEqual(p.segments, [Segment(text: "A & B", silenceMs: 150), Segment(text: "第二句", silenceMs: 0)])
    }

    func testEntitiesAreDecodedOnce() {
        XCTAssertEqual(SSML.decodeEntities("Tom&#8217;s &#x26; Jerry &amp;lt; &#39;x&apos; &bogus;"), "Tom’s & Jerry &lt; 'x' &bogus;")
    }

    func testConsecutiveBreaksFoldIntoThePieceBefore() {
        let p = SSML.parse("<speak>甲<break time=\"100ms\"/><break time=\"200ms\"/>乙</speak>")
        XCTAssertEqual(p.segments, [Segment(text: "甲", silenceMs: 300, explicitBreak: true), Segment(text: "乙", silenceMs: 0)])
    }

    func testRateWords() {
        XCTAssertEqual(SSML.rate("x-fast"), 2)
        XCTAssertEqual(SSML.rate("+50%"), 1.5, accuracy: 1e-9)
        XCTAssertEqual(SSML.rate("2.5"), 2.5)
        XCTAssertEqual(SSML.rate("garbage"), 1)
    }

    func testVoiceIdentifiers() {
        XCTAssertTrue(VoiceEntry.isWrappable(VoiceEntry.tingting.id))
        XCTAssertFalse(VoiceEntry.isWrappable(VoiceScheme.defaultTingting.providerIdentifier), "never one of our own voices")
        XCTAssertFalse(VoiceEntry.isWrappable("com.apple.speech.synthesis.voice.Bubbles"))
        XCTAssertFalse(VoiceEntry.isWrappable("com.sgr.grtts.voice.xunfei.zh-CN"))
    }
}

final class SpeechMarkersTests: XCTestCase {
    func testPartsOfAVoiceOverRequest() {
        let ssml = #"<speak><prosody rate="100%"><s><lang xml:lang="cmn-CN">可按住 转文字</lang></s><s><lang xml:lang="cmn-CN">文本栏</lang></s></prosody></speak>"#
        let ns = ssml as NSString
        let parts = SpeechMarkers.parts(ssml: ssml, samples: 8000)
        XCTAssertEqual(parts.map(\.mark), [.paragraph, .sentence, .word, .word, .sentence, .word])
        XCTAssertEqual(parts.map { ns.substring(with: $0.range) },
                       [ns.substring(with: NSRange(location: ns.range(of: "可按住").location,
                                                   length: NSMaxRange(ns.range(of: "文本栏")) - ns.range(of: "可按住").location)),
                        "可按住 转文字", "可按住", "转文字", "文本栏", "文本栏"])
        // 9 characters: the second word after 3, the second sentence after 6
        XCTAssertEqual(parts.map(\.sample), [0, 0, 0, 8000 * 3 / 9, 8000 * 6 / 9, 8000 * 6 / 9])
        XCTAssertEqual(SpeechMarkers.markers(ssml: ssml, samples: 8000).last?.byteSampleOffset, 8000 * 6 / 9 * 4)
        XCTAssertEqual(SpeechMarkers.parts(ssml: "<speak><break time=\"500ms\"/></speak>", samples: 100), [])
    }

    func testBookmarksWhereTheyStand() {
        let ssml = #"<speak><s>点赞</s><mark name="a"/><s>按钮</s><mark name='end'/></speak>"#
        let parts = SpeechMarkers.parts(ssml: ssml, samples: 4000)
        let marks = parts.filter { $0.mark == .bookmark }
        XCTAssertEqual(marks.map(\.name), ["a", "end"])
        XCTAssertEqual(marks.map(\.sample), [2000, 4000])
        // the bookmark comes before the sentence that starts where it stands
        let i = parts.firstIndex { $0.name == "a" }!
        XCTAssertEqual(parts[i + 1].mark, .sentence)
        XCTAssertEqual(SpeechMarkers.parts(ssml: #"<speak><mark name="x"/></speak>"#, samples: 10).map(\.name), ["x"])
    }
}
