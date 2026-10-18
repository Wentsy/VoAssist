import Foundation
import ObjectiveC

/// Before iOS 27 VoiceOver reads an item in parts (label, trait, value, hint), each a request of its own, and drops the
/// parts still to come when an announcement arrives. The system synthesizer this extension reads with sends one for
/// every utterance it is handed while VoiceOver is on: the utterance's text, for a braille display only, from this
/// process (TextToSpeech; on an iOS 26.7 iPad VoiceOver logged "Incoming announcement" and never asked for "按钮").
/// It sends nothing for a speech action without text, and it looks at the text right where the utterance is handed
/// over, on the caller's thread; the synthesis reads it later, on a thread of its own. So while this process hands an
/// utterance over (`SystemVoice.isHandingOver`), a speech action shows no text: rate, pitch and sound stay as they
/// were (measured on that iPad). Whenever the private class is not there as expected, nothing changes.
enum AnnouncementGuard {
    private static let lock = NSLock()
    private static var installed: Bool?

    /// Installs the guard once per process; true if it is in place.
    static func install() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let done = installed { return done }
        let done = swizzle()
        installed = done
        DiagnosticLog.write("announcement guard: \(done ? "on" : "not available")")
        return done
    }

    private static func swizzle() -> Bool {
        let textSel = NSSelectorFromString("string")
        guard let cls = NSClassFromString("TTSSpeechAction"),
              let method = class_getInstanceMethod(cls, textSel),
              method_getTypeEncoding(method).map({ String(cString: $0) })?.hasPrefix("@") == true else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { action in
            if SystemVoice.isHandingOver { return nil }
            return original(action, textSel)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }
}
