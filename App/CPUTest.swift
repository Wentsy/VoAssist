import AVFoundation

/// `-cpuTest` launch argument (development): the processor time the system voice takes per utterance in this process,
/// over many utterances, with `AVSpeechSynthesizer.write` called directly and through `SystemVoice.speak`. Environment:
/// `CT_N` utterances per kind (default 200), `CT_TEXT` the text. Prints `CT` lines, a line per 50 utterances.
enum CPUTest {
    static func run() {
        Thread {
            let env = ProcessInfo.processInfo.environment
            let n = Int(env["CT_N"] ?? "") ?? 200
            let text = env["CT_TEXT"] ?? "打开设置按钮"
            guard let voice = AVSpeechSynthesisVoice(identifier: VoiceEntry.tingting.id) ?? AVSpeechSynthesisVoice(language: "zh-CN") else {
                print("CT no voice"); return
            }
            print("CT voice \(voice.identifier), \(n) utterances of \"\(text)\" each way")
            // straight to the synthesizer
            let done = Done()
            let synth = AVSpeechSynthesizer()
            synth.delegate = done
            var batch = Batch(label: "write")
            for i in 1...n {
                let u = AVSpeechUtterance(string: text)
                u.voice = voice
                u.rate = AVSpeechUtteranceMaximumSpeechRate
                synth.write(u) { b in if let p = b as? AVAudioPCMBuffer { batch.samples += Int(p.frameLength); batch.buffers += 1 } }
                done.sem.wait()
                batch.tick(i)
            }
            // as the extension reads (SystemVoice: a box, a poll every 10 ms, the PCM converted)
            let sv = SystemVoice()
            batch = Batch(label: "SystemVoice")
            for i in 1...n {
                _ = sv.speak(text, voice: voice, rate: AVSpeechUtteranceMaximumSpeechRate, pitch: 1, isCancelled: { false }) { batch.samples += $0.count; batch.buffers += 1 }
                batch.tick(i)
            }
            print("CT done")
            DispatchQueue.main.async { devRunEnded() }
        }.start()
    }

    /// `-cpuBench`: has the voice extension measure itself (`CPUBench` there) and prints its "bench" lines. The log has
    /// to be on (`-logOn`).
    static func bench() {
        AUAudioUnit.instantiate(with: extensionComponent, options: .loadOutOfProcess) { au, _ in
            guard let au = au else { print("CT cannot load the extension"); return }
            Thread {
                au.fullState = [DiagnosticLog.commandKey: "clearLog"]
                au.fullState = [DiagnosticLog.commandKey: "cpuBench"]
                var seen = 0
                for _ in 0..<120 {
                    Thread.sleep(forTimeInterval: 2)
                    au.fullState = [DiagnosticLog.commandKey: "sendLog"]
                    let lines = (au.fullState?[DiagnosticLog.logKey] as? String ?? "").split(separator: "\n").filter { $0.contains("] bench") }
                    for l in lines.dropFirst(seen) { print("CT \(l)") }
                    seen = max(seen, lines.count)
                    if lines.contains(where: { $0.hasSuffix("bench: done") }) { break }
                }
                print("CT done")
                DispatchQueue.main.async { devRunEnded() }
            }.start()
        }
    }

    private final class Done: NSObject, AVSpeechSynthesizerDelegate {
        let sem = DispatchSemaphore(value: 0)
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { sem.signal() }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { sem.signal() }
    }

    private struct Batch {
        let label: String
        var samples = 0, buffers = 0
        var cpu = Batch.cpuSeconds(), wall = Date()

        init(label: String) { self.label = label }

        mutating func tick(_ i: Int) {
            guard i % 50 == 0 else { return }
            let c = Batch.cpuSeconds()
            print(String(format: "CT %@ %4d: %.1f ms CPU each, %.1f ms wall each, %d samples, %d buffers each", label, i,
                         (c - cpu) * 1000 / 50, Date().timeIntervalSince(wall) * 1000 / 50, samples / 50, buffers / 50))
            cpu = c; wall = Date(); samples = 0; buffers = 0
        }

        static func cpuSeconds() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
    }
}
