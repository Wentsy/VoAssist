import AVFoundation
import AudioToolbox

func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

/// The voice extension's audio component (project.yml: AudioComponents type/subtype/manufacturer).
let extensionComponent = AudioComponentDescription(
    componentType: fourCC("ausp"), componentSubType: fourCC("VoAs"), componentManufacturer: fourCC("Zdyi"),
    componentFlags: 0, componentFlagsMask: 0)

extension ExtensionProbe {
    /// The Apple voices the voice extension can use (see `UsableVoices`), from its state; nil if it cannot be loaded yet.
    static func usableVoices(done: @escaping ([VoiceEntry]?) -> Void) {
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, _ in
            guard let list = au?.fullState?[UsableVoices.stateKey] as? [[String: String]] else { done(nil); return }
            done(list.compactMap { d in
                guard let id = d["id"], let name = d["name"], let lang = d["lang"] else { return nil }
                return VoiceEntry(id: id, name: name, lang: lang)
            })
        }
    }
}

/// Drives the real voice extension the way the system does (loaded out of process, a speech request, then render calls)
/// and collects its audio. This answers the one question that matters before VoiceOver is involved: can the extension
/// call the system voices from inside its own process?
enum ExtensionProbe {
    struct Result {
        var lines: [String] = []
        var samples: [Float] = []
        var sampleRate = Double(SystemVoice.sampleRate)
        var ok = false
    }

    static func run(text: String, scheme: VoiceScheme, completion: @escaping (Result) -> Void) {
        var r = Result()
        // right after an install the component list can still lack it while it loads all the same (iOS 27): try anyway
        let listed = !AVAudioUnitComponentManager.shared().components(matching: extensionComponent).isEmpty
        r.lines.append(listed ? "扩展已登记" : "系统的组件列表里还没有本语音扩展，照样试着加载")
        let t0 = Date()
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, error in
            guard let au = au else {
                let e = error as NSError?
                r.lines.append("加载扩展失败（\(e?.domain ?? "") \(e?.code ?? 0)）\(e?.localizedDescription ?? "")")
                if !listed { r.lines.append("刚安装时请等半分钟或重启一次手机。") }
                completion(r)
                return
            }
            r.lines.append("加载扩展用时 \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            Thread {
                drive(au, text: text, scheme: scheme, into: &r)
                completion(r)
            }.start()
        }
    }

    private static func drive(_ au: AUAudioUnit, text: String, scheme: VoiceScheme, into r: inout Result) {
        // The app gets an XPC proxy, not our class: ask it by selector, as the system does.
        let voicesSel = NSSelectorFromString("speechVoices")
        let voices = au.responds(to: voicesSel) ? (au.perform(voicesSel)?.takeUnretainedValue() as? [AVSpeechSynthesisProviderVoice]) ?? [] : []
        r.lines.append("扩展向系统提供 \(voices.count) 个方案：" + voices.map { "\($0.name)（\($0.supportedLanguages.joined(separator: "、"))）" }.joined(separator: "，"))
        guard let pv = voices.first(where: { $0.identifier == scheme.providerIdentifier }) ?? voices.first else {
            r.lines.append("扩展没有给出音色，无法继续")
            return
        }
        let format = au.outputBusses[0].format
        r.sampleRate = format.sampleRate
        let frames: AUAudioFrameCount = 512
        au.maximumFramesToRender = max(au.maximumFramesToRender, frames)
        do {
            try au.allocateRenderResources()
        } catch {
            r.lines.append("allocateRenderResources 失败：\(error.localizedDescription)")
            return
        }
        defer { au.deallocateRenderResources() }

        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let request = AVSpeechSynthesisProviderRequest(ssmlRepresentation: "<speak>\(escaped)</speak>", voice: pv)
        let synthSel = NSSelectorFromString("synthesizeSpeechRequest:")
        guard au.responds(to: synthSel) else {
            r.lines.append("扩展代理不响应 synthesizeSpeechRequest:，无法自检（不影响旁白使用）")
            return
        }
        let abl = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { free(abl.unsafeMutablePointer) }
        let bytes = Int(frames) * MemoryLayout<Float>.size
        for i in 0..<abl.count {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: malloc(bytes))
        }
        defer { for i in 0..<abl.count { free(abl[i].mData) } }
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        let render = au.renderBlock

        /// One request, rendered to the end. Pulls in real time until the first sound (the leading silence then measures
        /// the latency as a host would hear it), faster after that.
        func once() -> (speech: [Float], firstSoundMs: Int, complete: Bool, error: OSStatus) {
            var out: [Float] = []
            var lead = 0
            let t0 = Date()
            _ = au.perform(synthSel, with: request)
            var complete = false
            let maxFrames = Int(format.sampleRate * 30)
            while out.count < maxFrames {
                let played = Double(lead + out.count) / format.sampleRate
                let elapsed = Date().timeIntervalSince(t0) * (out.isEmpty ? 1 : 8)
                if played > elapsed { Thread.sleep(forTimeInterval: min(played - elapsed, 0.02)) }
                for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(bytes) }
                var flags = AudioUnitRenderActionFlags()
                let status = render(&flags, &ts, frames, 0, abl.unsafeMutablePointer, nil)
                if status != noErr { return (out, -1, false, status) }
                ts.mSampleTime += Double(frames)
                let n = min(Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size, Int(frames))
                if let d = abl[0].mData?.assumingMemoryBound(to: Float.self), n > 0 {
                    let chunk = UnsafeBufferPointer(start: d, count: n)
                    if out.isEmpty, let k = chunk.firstIndex(where: { $0 != 0 }) {
                        lead += k
                        out.append(contentsOf: chunk[k...])
                    } else if out.isEmpty {
                        lead += n
                    } else {
                        out.append(contentsOf: chunk)
                    }
                }
                if flags.contains(.offlineUnitRenderAction_Complete) { complete = true; break }
            }
            return (out, Int(Double(lead) / format.sampleRate * 1000), complete, noErr)
        }

        for (i, label) in ["第一次（冷启动）", "第二次（已预热）"].enumerated() {
            let (speech, firstMs, complete, err) = once()
            if err != noErr {
                r.lines.append("\(label)渲染出错 OSStatus \(err)")
                return
            }
            let peak = speech.reduce(0) { max($0, abs($1)) }
            guard peak > 0.01 else {
                r.lines.append("失败：扩展只给出了静音——扩展进程里拿不到系统语音的声音")
                return
            }
            r.lines.append(String(format: "%@：%.2f 秒语音，首个声音前的静音 %d ms%@", label,
                                  Double(speech.count) / format.sampleRate, firstMs, complete ? "" : "（未收到结束标记）"))
            if i == 1 {
                r.samples = speech
                r.ok = true
            }
        }
        r.lines.append("成功：扩展在自己的进程里调用系统声音正常（\(pv.name)）")
    }
}
