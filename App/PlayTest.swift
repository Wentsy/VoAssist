import AVFoundation
import AudioToolbox

/// `-playTest` launch argument (development): the long items mixing Chinese and English of `FocusTest`, each played
/// through the extension as a host plays it, in real time (256 frames a pull), to its end or for `PT_PLAY` seconds before
/// the next; `PT_ROUNDS` rounds (1), at `PT_RATE` (VoiceOver's rate in percent, 100). Without VoiceOver: whether
/// playback runs dry while the extension synthesizes in step with it (`BoostSynthesis.paceBelow`), when the sound
/// starts, how often it waited, and the extension's processor time and energy before and after, in the diagnostic log
/// (`-logOn -clearLog -playTest`, then `-printLog`).
enum PlayTest {
    static func run() {
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, _ in
            guard let au = au else { print("PT cannot load the extension"); return }
            Thread {
                let env = ProcessInfo.processInfo.environment
                let play = Double(env["PT_PLAY"] ?? "") ?? .infinity
                let rounds = Int(env["PT_ROUNDS"] ?? "") ?? 1
                let rate = env["PT_RATE"] ?? "100"
                let voices = (au.perform(NSSelectorFromString("speechVoices"))?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? []
                guard let voice = voices.first(where: { $0.primaryLanguages.contains("zh-CN") }) ?? voices.first else { print("PT no voice"); return }
                au.maximumFramesToRender = max(au.maximumFramesToRender, 512)
                do { try au.allocateRenderResources() } catch { print("PT allocate failed: \(error)"); return }
                defer { au.deallocateRenderResources() }
                let format = au.outputBusses[0].format
                let frames: AUAudioFrameCount = 256
                let abl = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
                defer { free(abl.unsafeMutablePointer) }
                let bytes = Int(frames) * MemoryLayout<Float>.size
                for i in 0..<abl.count { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: malloc(bytes)) }
                defer { for i in 0..<abl.count { free(abl[i].mData) } }
                var ts = AudioTimeStamp()
                ts.mFlags = .sampleTimeValid
                let render = au.renderBlock
                let synth = NSSelectorFromString("synthesizeSpeechRequest:")
                print("PT voice \(voice.name), rate \(rate)%, \(play.isFinite ? "\(play) s each" : "each to its end")")
                au.fullState = [DiagnosticLog.commandKey: "usage"]
                for round in 0..<rounds {
                    for (i, text) in FocusTest.longItems.enumerated() {
                        let ssml = "<speak><prosody rate=\"\(rate)%\">\(text)</prosody></speak>"
                        _ = au.perform(synth, with: AVSpeechSynthesisProviderRequest(ssmlRepresentation: ssml, voice: voice))
                        waitAsVoiceOverDoes()
                        let began = Date()
                        var pulled = 0
                        var complete = false
                        while !complete && Date().timeIntervalSince(began) < play {
                            let wait = began.addingTimeInterval(Double(pulled) / format.sampleRate).timeIntervalSinceNow
                            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                            for k in 0..<abl.count { abl[k].mDataByteSize = UInt32(bytes) }
                            var flags = AudioUnitRenderActionFlags()
                            guard render(&flags, &ts, frames, 0, abl.unsafeMutablePointer, nil) == noErr else { break }
                            ts.mSampleTime += Double(frames)
                            pulled += Int(frames)
                            complete = flags.contains(.offlineUnitRenderAction_Complete)
                        }
                        if !complete { _ = au.perform(NSSelectorFromString("cancelSpeechRequest")) }
                        print(String(format: "PT round %d item %d: %.1f s played%@", round, i, Double(pulled) / format.sampleRate, complete ? ", complete" : ", cut short"))
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
                au.fullState = [DiagnosticLog.commandKey: "usage"]
                print("PT done")
                DispatchQueue.main.async { devRunEnded() }
            }.start()
        }
    }
}
