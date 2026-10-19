import AVFoundation
import AudioToolbox

/// `-stallTest` launch argument (development): many short items in a row, as swiping through a list sends them, with
/// now and then a long one cut short, to catch the rare item whose end comes late. Run with `-logOn -clearLog`, then
/// `-printLog`: the requests' "done in" and any "slow end" lines (when each kind of callback came, and how long the
/// extension's main queue was held up meanwhile).
enum StallTest {
    static func run() {
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, _ in
            guard let au = au else { print("ST cannot load the extension"); return }
            Thread {
                let voices = (au.perform(NSSelectorFromString("speechVoices"))?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? []
                guard let voice = voices.first else { print("ST no voice"); return }
                au.maximumFramesToRender = max(au.maximumFramesToRender, 512)
                do { try au.allocateRenderResources() } catch { print("ST allocate failed: \(error)"); return }
                defer { au.deallocateRenderResources() }
                let synth = NSSelectorFromString("synthesizeSpeechRequest:")
                func send(_ text: String) {
                    _ = au.perform(synth, with: AVSpeechSynthesisProviderRequest(ssmlRepresentation: "<speak>\(text)</speak>", voice: voice))
                }
                let items = ["发送日志", "按住 说话", "打开 Safari 浏览器", "Wi-Fi 设置", "记录日志", "微信", "App Store 有更新", "设置"]
                let long = String(repeating: "今天下午三点在会议室开会，请大家准时参加，带上上周的报告和电脑。", count: 4)
                send("预热")
                Thread.sleep(forTimeInterval: 3)
                for i in 0..<80 {
                    if i % 8 == 7 {
                        send(long)
                        Thread.sleep(forTimeInterval: 0.06)
                        _ = au.perform(NSSelectorFromString("cancelSpeechRequest"))
                    }
                    send(items[i % items.count])
                    Thread.sleep(forTimeInterval: 0.3)
                }
                Thread.sleep(forTimeInterval: 1)
                print("ST done")
                DispatchQueue.main.async { devRunEnded() }
            }.start()
        }
    }
}
