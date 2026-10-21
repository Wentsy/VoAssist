import UIKit

/// `-focusTest` launch argument (development): moves VoiceOver's focus over a few controls by itself, round after
/// round, so what VoiceOver sends the voice for each (label, trait, value, hint) shows in the diagnostic log and the
/// system log without anyone swiping. Two of them mix Chinese and English, for the joins. VoiceOver has to be on, with the voice under test.
/// `FT_SET=long`: longer items mixing Chinese and English as in a chat list or a web page instead (to compare the power
/// the whole device draws with another voice).
enum FocusTest {
    static let longItems = [
        "张三，明天的 meeting 改到下午 3 点，记得带 MacBook 和 iPad，上午 10:42，2 条未读",
        "工作群（128），王五：PPT 我已经传到 Google Drive 了，大家有空 review 一下，昨天",
        "李四：这个 bug 在 iOS 27 上能复现吗？我这边 TestFlight 的 build 29 没问题",
        "苹果今天发布了 iOS 27.2 更新，新增 VoiceOver 的实时识别功能，并修复了 Bluetooth 耳机连接不稳定的问题。用户可以在设置的通用里检查更新。",
        "淘宝，你关注的 AirPods Pro 降价了，现价 1,499 元",
        "微信支付：你在 Apple Store 有一笔订单待付款，金额 6,999.00 元",
        "Wi-Fi，已连接 Office-5G，信号强",
        "网易云音乐，正在播放 Taylor Swift 的 Love Story",
    ]

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
            if ProcessInfo.processInfo.environment["FT_SET"] == "long" {
                let labels = FocusTest.longItems.map { text -> UILabel in
                    let l = UILabel()
                    l.text = text
                    l.numberOfLines = 0
                    return l
                }
                let stack = UIStackView(arrangedSubviews: labels)
                stack.axis = .vertical
                stack.spacing = 16
                stack.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                    stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                targets = labels
                return
            }
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
            // Chinese and English in one name: how the voices join
            let safari = UIButton(type: .system)
            safari.setTitle("打开Safari浏览器", for: .normal)
            let wifi = UIButton(type: .system)
            wifi.setTitle("Wi-Fi 设置", for: .normal)
            let stack = UIStackView(arrangedSubviews: [send, talk, toggle, field, safari, wifi])
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
            targets = [send, talk, toggle, field, safari, wifi]
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
