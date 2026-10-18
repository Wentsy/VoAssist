import AVFoundation
import AudioToolbox

/// `-interruptTest` launch argument (development): fast swiping, as the extension sees it. Drives the extension as a host
/// does: a long item cut short after 60 ms by the next, short one, in turns with a short one alone; then six long items
/// in a row, each cut short by the next after 80 ms, and a short one (synthesizers just stopped are used again). The
/// timings are in the diagnostic log (`-logOn -clearLog -interruptTest`, then `-printLog`): "first audio after" of each
/// request, and how long its `synthesizeSpeechRequest` took (the host's calls come one after another).
enum InterruptTest {
    static func run() {
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, _ in
            guard let au = au else { print("IT cannot load the extension"); return }
            Thread {
                let voices = (au.perform(NSSelectorFromString("speechVoices"))?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? []
                guard let voice = voices.first else { print("IT no voice"); return }
                au.maximumFramesToRender = max(au.maximumFramesToRender, 512)
                do { try au.allocateRenderResources() } catch { print("IT allocate failed: \(error)"); return }
                defer { au.deallocateRenderResources() }
                let synth = NSSelectorFromString("synthesizeSpeechRequest:")
                func send(_ text: String) {
                    _ = au.perform(synth, with: AVSpeechSynthesisProviderRequest(ssmlRepresentation: "<speak>\(text)</speak>", voice: voice))
                }
                let long = String(repeating: "今天下午三点在会议室开会，请大家准时参加，带上上周的报告和电脑。", count: 8)
                send("预热")
                Thread.sleep(forTimeInterval: 2)
                for i in 0..<10 {
                    if i % 2 == 0 {
                        send(long)
                        Thread.sleep(forTimeInterval: 0.06)
                        _ = au.perform(NSSelectorFromString("cancelSpeechRequest"))
                    }
                    send("发送日志")
                    print("IT round \(i): \(i % 2 == 0 ? "after a long item cut short" : "alone")")
                    Thread.sleep(forTimeInterval: 1.2)
                }
                for i in 0..<6 {
                    send(long)
                    print("IT burst \(i)")
                    Thread.sleep(forTimeInterval: 0.08)
                    _ = au.perform(NSSelectorFromString("cancelSpeechRequest"))
                }
                send("发送日志")
                Thread.sleep(forTimeInterval: 1.2)
                print("IT done")
                DispatchQueue.main.async { devRunEnded() }
            }.start()
        }
    }
}
