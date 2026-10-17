import AVFoundation
import AudioToolbox

/// Development (launch argument `-latency`): how long after a speech request the first sound comes, from our voice
/// extension and from Apple's own speech audio unit, each driven the way VoiceOver drives it (loaded out of process, a
/// request, render calls in real time). Prints `LATENCY` lines; changes and saves nothing.
enum LatencyProbe {
    static func run() {
        Thread {
            // every speech synthesizer audio unit (the wildcard lookup of AVAudioUnitComponentManager finds none)
            var all: [AudioComponentDescription] = []
            var want = AudioComponentDescription(componentType: fourCC("ausp"), componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            var comp = AudioComponentFindNext(nil, &want)
            while let c = comp {
                var d = AudioComponentDescription()
                AudioComponentGetDescription(c, &d)
                var name: Unmanaged<CFString>?
                AudioComponentCopyName(c, &name)
                print("LATENCY component: \(name?.takeRetainedValue() as String? ?? "?") manufacturer \(d.componentManufacturer == fourCC("appl") ? "appl" : String(d.componentManufacturer))")
                all.append(d)
                comp = AudioComponentFindNext(c, &want)
            }
            // and whatever the component manager lists as a speech synthesizer
            for c in AVAudioUnitComponentManager.shared().components(passingTest: { c, _ in c.audioComponentDescription.componentType == fourCC("ausp") }) {
                let d = c.audioComponentDescription
                print("LATENCY listed: \(c.name) [\(c.manufacturerName)] subtype \(d.componentSubType)")
                if !all.contains(where: { $0.componentSubType == d.componentSubType && $0.componentManufacturer == d.componentManufacturer }) { all.append(d) }
            }
            print("LATENCY all ausp count \(all.count), total components \(AVAudioUnitComponentManager.shared().components(passingTest: { _, _ in true }).count)")
            if all.isEmpty { all.append(extensionComponent) }
            let ours = all.first { $0.componentManufacturer == fourCC("Zdyi") }
            let apple = all.first { $0.componentManufacturer == fourCC("appl") }
            let ourVoice = VoiceScheme.shared().first { LanguageRuns.isChinese($0.language) }?.providerIdentifier
            for (label, comp, voiceMatch) in [("ours", ours, ourVoice), ("apple", apple, "Tingting")] {
                guard let comp = comp, let match = voiceMatch else { print("LATENCY \(label): not found"); continue }
                measure(label, comp, voiceMatch: match)
            }
            print("LATENCY done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }

    private static func measure(_ label: String, _ desc: AudioComponentDescription, voiceMatch: String) {
        let sem = DispatchSemaphore(value: 0)
        var unit: AUAudioUnit?
        let t0 = Date()
        AUAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { au, _ in
            unit = au
            sem.signal()
        }
        sem.wait()
        guard let au = unit else { print("LATENCY \(label): cannot load"); return }
        print(String(format: "LATENCY %@: loaded in %.0f ms", label, Date().timeIntervalSince(t0) * 1000))
        let voicesSel = NSSelectorFromString("speechVoices")
        let voices = (au.perform(voicesSel)?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? []
        guard let voice = voices.first(where: { $0.identifier.contains(voiceMatch) }) ?? voices.first(where: { $0.primaryLanguages.contains("zh-CN") }) else {
            print("LATENCY \(label): no voice among \(voices.count)")
            return
        }
        print("LATENCY \(label): voice \(voice.name) \(voice.identifier)")
        let format = au.outputBusses[0].format
        let frames: AUAudioFrameCount = 256
        au.maximumFramesToRender = max(au.maximumFramesToRender, 4096)
        do { try au.allocateRenderResources() } catch { print("LATENCY \(label): allocate failed \(error)"); return }
        defer { au.deallocateRenderResources() }
        let abl = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { free(abl.unsafeMutablePointer) }
        let bytes = Int(frames) * MemoryLayout<Float>.size
        for i in 0..<abl.count { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: malloc(bytes)) }
        defer { for i in 0..<abl.count { free(abl[i].mData) } }
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        let render = au.renderBlock
        let synthSel = NSSelectorFromString("synthesizeSpeechRequest:")
        let requests = [
            ("cold 设置", "<speak><prosody rate=\"250%\"><s>设置</s><s>按钮</s></prosody></speak>"),
            ("warm 通用", "<speak><prosody rate=\"250%\"><s>通用</s><s>按钮</s></prosody></speak>"),
            ("warm 辅助功能", "<speak><prosody rate=\"250%\"><s>辅助功能</s><s>按钮</s></prosody></speak>"),
            ("warm 屏幕使用时间", "<speak><prosody rate=\"250%\"><s>屏幕使用时间</s></prosody></speak>"),
            ("warm 电池", "<speak><prosody rate=\"250%\"><s>电池</s><s>按钮</s></prosody></speak>"),
            ("mixed Safari 浏览器", "<speak><prosody rate=\"250%\"><s>Safari 浏览器</s><s>按钮</s></prosody></speak>"),
            ("mixed 打开 Wi-Fi", "<speak><prosody rate=\"250%\"><s>打开 Wi-Fi</s></prosody></speak>"),
            ("warm 蓝牙", "<speak><prosody rate=\"250%\"><s>蓝牙</s><s>按钮</s></prosody></speak>"),
        ]
        for (name, ssml) in requests {
            let req = AVSpeechSynthesisProviderRequest(ssmlRepresentation: ssml, voice: voice)
            let start = Date()
            _ = au.perform(synthSel, with: req)
            let returned = Date().timeIntervalSince(start)
            // pull in real time, as a player does, until the first sound
            var pulled = 0
            var first: Double = -1
            while first < 0 && pulled < Int(format.sampleRate * 2) {
                let due = start.addingTimeInterval(returned + Double(pulled) / format.sampleRate)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(bytes) }
                var flags = AudioUnitRenderActionFlags()
                guard render(&flags, &ts, frames, 0, abl.unsafeMutablePointer, nil) == noErr else { break }
                ts.mSampleTime += Double(frames)
                let n = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                if let d = abl[0].mData?.assumingMemoryBound(to: Float.self),
                   let k = UnsafeBufferPointer(start: d, count: min(n, Int(frames))).firstIndex(where: { abs($0) > 0.001 }) {
                    first = returned + Double(pulled + k) / format.sampleRate
                }
                pulled += Int(frames)
                if flags.contains(.offlineUnitRenderAction_Complete) && first < 0 { break }
            }
            // drain the rest so the next request starts clean
            var guardCount = 0
            while guardCount < 2000 {
                for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(bytes) }
                var flags = AudioUnitRenderActionFlags()
                if render(&flags, &ts, frames, 0, abl.unsafeMutablePointer, nil) != noErr || flags.contains(.offlineUnitRenderAction_Complete) { break }
                ts.mSampleTime += Double(frames)
                guardCount += 1
            }
            print(String(format: "LATENCY %@ %@: request returned after %.0f ms, first sound at %.0f ms", label, name, returned * 1000, first * 1000))
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
