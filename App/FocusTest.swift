import UIKit

/// `-focusTest` launch argument (development): moves VoiceOver's focus over a few controls by itself, round after
/// round, so what VoiceOver sends the voice for each (label, trait, value, hint) shows in the diagnostic log and the
/// system log without anyone swiping. VoiceOver has to be on, with the voice under test.
enum FocusTest {
    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.keyWindow?.rootViewController else { print("FT no window"); return }
            let vc = Controller()
            vc.modalPresentationStyle = .fullScreen
            root.present(vc, animated: false)
        }
    }

    private final class Controller: UIViewController {
        private var targets: [UIView] = []
        private let dwell = Double(ProcessInfo.processInfo.environment["FT_DWELL"] ?? "") ?? 5
        private let rounds = Int(ProcessInfo.processInfo.environment["FT_ROUNDS"] ?? "") ?? 2

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let send = UIButton(type: .system)
            send.setTitle("发送日志", for: .normal)
            send.accessibilityHint = "把日志分享给开发者"
            let talk = UIButton(type: .system)
            talk.setTitle("按住 说话", for: .normal)
            let toggle = UISwitch()
            toggle.accessibilityLabel = "记录日志"
            let field = UITextField()
            field.placeholder = "输入消息"
            field.borderStyle = .roundedRect
            let stack = UIStackView(arrangedSubviews: [send, talk, toggle, field])
            stack.axis = .vertical
            stack.spacing = 40
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                field.widthAnchor.constraint(equalToConstant: 240),
            ])
            targets = [send, talk, toggle, field]
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            print("FT VoiceOver running: \(UIAccessibility.isVoiceOverRunning)")
            step(0)
        }

        private func step(_ i: Int) {
            guard i < targets.count * rounds else {
                print("FT done")
                devRunEnded()
                return
            }
            let t = targets[i % targets.count]
            print("FT focus \(i): \(t.accessibilityLabel ?? "-")")
            UIAccessibility.post(notification: .layoutChanged, argument: t)
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell) { self.step(i + 1) }
        }
    }
}
