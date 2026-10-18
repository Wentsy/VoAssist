import AVFoundation
import AudioToolbox

/// `-voiceCompare` launch argument (development): how the third-party voices on this phone behave, ours next to any
/// other, as every host sees them, and Apple's Tingting for reference. Through the speech API: the callbacks of three
/// queued utterances (start, ranges, finish), spoken at volume 0. Through each speech audio unit: its output format,
/// how soon a request returns, how it renders to the end, and the markers it sends. Nothing of another app is opened up.
enum VoiceCompare {
    static func run() {
        Thread {
            let all = AVSpeechSynthesisVoice.speechVoices().filter { LanguageRuns.isChinese($0.language) && $0.language.hasPrefix("zh-CN") }
            let third = all.filter { !$0.identifier.hasPrefix("com.apple.") }
            print("VC third-party zh-CN voices: " + third.map { "\($0.name) [\($0.identifier)]" }.joined(separator: ", "))
            var picks = third
            if let apple = all.first(where: { $0.identifier.contains("Tingting") }) { picks.append(apple) }
            for v in picks { speechAPI(v) }
            audioUnits()
            print("VC done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }

    private final class Recorder: NSObject, AVSpeechSynthesizerDelegate {
        private let t0 = Date()
        private let lock = NSLock()
        private(set) var lines: [String] = []

        func note(_ s: String) {
            lock.lock()
            lines.append(String(format: "%6.0f ms  %@", Date().timeIntervalSince(t0) * 1000, s))
            lock.unlock()
        }

        func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { note("didStart \(u.speechString)") }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { note("didFinish \(u.speechString)") }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { note("didCancel \(u.speechString)") }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
            note("willSpeak \((u.speechString as NSString).substring(with: r)) of \(u.speechString)")
        }
    }

    /// Three utterances queued at once, as VoiceOver before iOS 27 seems to speak an item's parts.
    private static func speechAPI(_ voice: AVSpeechSynthesisVoice) {
        let rec = Recorder()
        var synth: AVSpeechSynthesizer?
        DispatchQueue.main.sync {
            let s = AVSpeechSynthesizer()
            s.delegate = rec
            for text in ["发送日志", "按钮", "轻点两下以激活"] {
                let u = AVSpeechUtterance(string: text)
                u.voice = voice
                u.volume = 0
                s.speak(u)
            }
            synth = s
        }
        Thread.sleep(forTimeInterval: 6)
        DispatchQueue.main.sync { synth?.stopSpeaking(at: .immediate) }
        print("VC speech API, \(voice.name) [\(voice.identifier)]:\n" + rec.lines.map { "VC   " + $0 }.joined(separator: "\n"))
    }

    /// Every third-party speech audio unit, driven as a host drives it.
    private static func audioUnits() {
        var want = AudioComponentDescription(componentType: fourCC("ausp"), componentSubType: 0, componentManufacturer: 0,
                                             componentFlags: 0, componentFlagsMask: 0)
        var comp = AudioComponentFindNext(nil, &want)
        while let c = comp {
            var d = AudioComponentDescription()
            AudioComponentGetDescription(c, &d)
            var name: Unmanaged<CFString>?
            AudioComponentCopyName(c, &name)
            let label = name?.takeRetainedValue() as String? ?? "?"
            if d.componentManufacturer != fourCC("appl") { probe(d, label: label) }
            comp = AudioComponentFindNext(c, &want)
        }
    }

    private static func probe(_ desc: AudioComponentDescription, label: String) {
        let sem = DispatchSemaphore(value: 0)
        var unit: AUAudioUnit?
        AUAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { au, _ in unit = au; sem.signal() }
        sem.wait()
        guard let au = unit else { print("VC unit \(label): cannot load"); return }
        let voices = (au.perform(NSSelectorFromString("speechVoices"))?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? []
        print("VC unit \(label): " + voices.map { "\($0.name) \($0.primaryLanguages)/\($0.supportedLanguages) size \($0.voiceSize) v\($0.version)" }.joined(separator: "; "))
        guard let voice = voices.first(where: { $0.primaryLanguages.contains { $0.hasPrefix("zh") || $0.hasPrefix("cmn") } }) ?? voices.first else { return }
        let format = au.outputBusses[0].format
        let asbd = format.streamDescription.pointee
        print("VC unit \(label): format \(format.sampleRate) Hz, \(format.channelCount) ch, \(format.commonFormat.rawValue) common, interleaved \(format.isInterleaved), \(asbd.mBytesPerFrame) bytes/frame; maxFrames \(au.maximumFramesToRender), latency \(au.latency), tail \(au.tailTime)")
        // markers, if the proxy lets a host set the block
        var markers: [String] = []
        let lock = NSLock()
        let setter = NSSelectorFromString("setSpeechSynthesisOutputMetadataBlock:")
        if au.responds(to: setter) {
            let block: @convention(block) ([AVSpeechSynthesisMarker], AVSpeechSynthesisProviderRequest) -> Void = { list, _ in
                lock.lock()
                markers.append(list.map { "\($0.mark.rawValue)@\($0.byteSampleOffset) \($0.textRange.location)+\($0.textRange.length)" }.joined(separator: " "))
                lock.unlock()
            }
            au.perform(setter, with: block)
        } else {
            print("VC unit \(label): no marker block setter on the proxy")
        }
        au.maximumFramesToRender = max(au.maximumFramesToRender, 1024)
        do { try au.allocateRenderResources() } catch { print("VC unit \(label): allocate failed \(error)"); return }
        defer { au.deallocateRenderResources() }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256) else { return }
        let render = au.renderBlock
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        for ssml in [#"<speak><lang xml:lang="cmn"><prosody rate="99.99998%" volume="-1.4116213dB">发送日志</prosody></lang></speak>"#,
                     #"<speak><lang xml:lang="cmn"><prosody rate="99.99998%" volume="-1.4116213dB">按钮</prosody></lang></speak>"#] {
            lock.lock(); markers.removeAll(); lock.unlock()
            let req = AVSpeechSynthesisProviderRequest(ssmlRepresentation: ssml, voice: voice)
            let t0 = Date()
            _ = au.perform(NSSelectorFromString("cancelSpeechRequest"))
            _ = au.perform(NSSelectorFromString("synthesizeSpeechRequest:"), with: req)
            waitAsVoiceOverDoes()
            let returned = Date().timeIntervalSince(t0) * 1000
            var pulls: [String] = []
            var total = 0, firstSound = -1, completeAt = -1
            for i in 0..<400 {
                let due = t0.addingTimeInterval(Double(i) * 256 / format.sampleRate)
                if due.timeIntervalSinceNow > 0 { Thread.sleep(forTimeInterval: due.timeIntervalSinceNow) }
                buf.frameLength = 256
                let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
                for j in 0..<abl.count { abl[j].mDataByteSize = 256 * asbd.mBytesPerFrame }
                var flags = AudioUnitRenderActionFlags()
                let status = render(&flags, &ts, 256, 0, buf.mutableAudioBufferList, nil)
                ts.mSampleTime += 256
                let got = Int(abl[0].mDataByteSize / max(asbd.mBytesPerFrame, 1))
                let loud: Bool = {
                    if let f = buf.floatChannelData?[0] { return (0..<min(got, 256)).contains { abs(f[$0]) > 0.001 } }
                    if let s = buf.int16ChannelData?[0] { return (0..<min(got, 256)).contains { abs(Int(s[$0])) > 30 } }
                    return false
                }()
                if loud && firstSound < 0 { firstSound = i }
                total += got
                let complete = flags.contains(.offlineUnitRenderAction_Complete)
                if i < 3 || complete || status != noErr { pulls.append("#\(i) \(got)f\(complete ? " complete" : "")\(status != noErr ? " err \(status)" : "")") }
                if complete { completeAt = i; break }
            }
            lock.lock(); let got = markers; lock.unlock()
            print(String(format: "VC unit %@ %@: returned %.0f ms, first sound in pull %d, complete at pull %d, %d frames; pulls %@; markers %@",
                         label, (ssml as NSString).substring(with: (ssml as NSString).range(of: "(?<=>)[^<>]+(?=</prosody>)", options: .regularExpression)),
                         returned, firstSound, completeAt, total, pulls.joined(separator: ", "), got.isEmpty ? "none" : got.joined(separator: " | ")))
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
