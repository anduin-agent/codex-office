import AppKit

enum MenuBarMetric: String {
    case todayTokens = "today_tokens"
    case tokenSpeed = "token_speed"
    case planRemaining = "plan_remaining"
}

struct TokenUsageSnapshot {
    let payload: [String: Any]
    let liveStatus: String
    let tokensPerMinute: Int?
    let todayStatus: String
    let todayTokens: Int?
    let quotaPercent: Double?
    let quotaWindow: Int?

    init?(data: Data) {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let liveStatus = payload["live_status"] as? String,
              ["ok", "partial", "loading", "unavailable"].contains(liveStatus)
        else { return nil }
        self.init(payload: payload)
    }

    init(payload: [String: Any]) {
        self.payload = payload
        self.liveStatus = payload["live_status"] as? String ?? "unavailable"
        self.tokensPerMinute = payload["tokens_per_minute"] as? Int
        self.todayStatus = payload["today_status"] as? String ?? "unavailable"
        self.todayTokens = payload["today_tokens"] as? Int
        let quota = payload["quota"] as? [String: Any]
        self.quotaPercent = quota?["remaining_percent"] as? Double
        self.quotaWindow = quota?["window_minutes"] as? Int
    }

    private static let groupedCount = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))
    private static let compactCount = groupedCount.notation(.compactName).precision(.fractionLength(0...1))
        .rounded(rule: .toNearestOrAwayFromZero)

    private func quotaText(in language: OfficeLanguage) -> String? {
        quotaPercent.map { $0.formatted(.number.precision(.fractionLength(0...1)).locale(language.locale)) + "%" }
    }

    func title(for metric: MenuBarMetric, language: OfficeLanguage) -> String {
        switch metric {
        case .todayTokens: return todayTokens.map { $0.formatted(Self.compactCount) } ?? "—"
        case .tokenSpeed: return tokensPerMinute.map { $0.formatted(Self.compactCount) + "/min" } ?? "—"
        case .planRemaining: return quotaText(in: language) ?? "—"
        }
    }

    func description(for metric: MenuBarMetric, language: OfficeLanguage) -> String {
        switch metric {
        case .todayTokens:
            if let todayTokens {
                let count = todayTokens.formatted(Self.groupedCount)
                let note = todayStatus == "partial" ? language.text(" · 数据不完整", " · Partial data") : ""
                return language.text("今日：\(count) token", "Today · \(count) tokens") + note
            }
            return todayStatus == "loading" ? language.text("正在读取今日用量", "Loading today’s usage")
                : language.text("今日用量不可用", "Today’s usage is unavailable")
        case .tokenSpeed:
            if let rate = tokensPerMinute {
                let count = rate.formatted(Self.groupedCount)
                let note = liveStatus == "partial" ? language.text(" · 数据不完整", " · Partial data") : ""
                return language.text("最近 1 分钟：\(count) tokens/min", "Last minute · \(count) tokens/min") + note
            }
            return liveStatus == "loading" ? language.text("正在读取 token 用量", "Loading token usage")
                : language.text("实时用量不可用", "Live usage is unavailable")
        case .planRemaining:
            guard let quotaText = quotaText(in: language) else {
                return language.text("套餐余量：本机暂无有效记录", "No current local quota record")
            }
            let label = switch quotaWindow {
            case 300: language.text("5 小时额度剩余", "5-hour quota remaining")
            case 10_080: language.text("套餐周余量", "Weekly quota remaining")
            default: language.text("套餐余量", "Plan quota remaining")
            }
            if payload["quota_source"] as? String == "live" {
                return language.text("\(label)：\(quotaText)（实时账户额度）", "\(label) · \(quotaText) (live account quota)")
            }
            return language.text("\(label)：\(quotaText)（本机最近记录）", "\(label) · \(quotaText) (last local record)")
        }
    }
}

/// A positive token rate sets the pace of the menu bar robot's walk.
@MainActor
final class TokenMeter: NSObject {
    private struct Pace: Equatable {
        let minimumRate: Int
        let frameInterval: TimeInterval
        let amplitude: CGFloat
    }

    private static let paces = [
        Pace(minimumRate: 1, frameInterval: 0.340, amplitude: 0.30),
        Pace(minimumRate: 20_000, frameInterval: 0.270, amplitude: 0.42),
        Pace(minimumRate: 60_000, frameInterval: 0.220, amplitude: 0.54),
        Pace(minimumRate: 100_000, frameInterval: 0.175, amplitude: 0.66),
        Pace(minimumRate: 250_000, frameInterval: 0.140, amplitude: 0.78),
        Pace(minimumRate: 500_000, frameInterval: 0.112, amplitude: 0.90),
        Pace(minimumRate: 750_000, frameInterval: 0.090, amplitude: 1.02),
        Pace(minimumRate: 1_000_000, frameInterval: 0.072, amplitude: 1.14),
        Pace(minimumRate: 2_500_000, frameInterval: 0.058, amplitude: 1.25),
    ]

    private weak var button: NSStatusBarButton?
    private let idle = TokenMeter.robotFrame(pose: .idle)
    private var frames: [NSImage] = []
    private var timer: Timer?
    private var frame = 0
    private var rate: Int?
    private var pace: Pace?

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        button.image = idle
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    func update(rate: Int?) {
        self.rate = rate
        updateMotion()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func updateMotion() {
        let next: Pace?
        if let rate, rate > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            next = Self.paces.last { rate >= $0.minimumRate }
        } else {
            next = nil
        }
        guard next != pace else { return }
        timer?.invalidate()
        timer = nil
        pace = next
        if let next {
            frames = (0..<8).map { Self.robotFrame(pose: .walking(frame: $0, amplitude: next.amplitude)) }
            advance()
            let timer = Timer(timeInterval: next.frameInterval, target: self, selector: #selector(advance),
                              userInfo: nil, repeats: true)
            timer.tolerance = next.frameInterval / 8
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            frames.removeAll()
            button?.image = idle
        }
    }

    @objc private func advance() {
        button?.image = frames[frame]
        frame = (frame + 1) % frames.count
    }

    private struct RobotPose {
        let stride: CGFloat
        let step: CGFloat
        let bounce: CGFloat

        static let idle = RobotPose(stride: 0, step: 0, bounce: 0)

        static func walking(frame: Int, amplitude: CGFloat) -> RobotPose {
            let phase = Double(frame) * .pi / 4
            let step = CGFloat(sin(phase)) * amplitude
            return RobotPose(stride: CGFloat(cos(phase)) * amplitude, step: step, bounce: abs(step) * 0.50)
        }
    }

    private static func robotFrame(pose: RobotPose) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 17), flipped: false) { _ in
            NSColor.black.set()
            let bounce = pose.bounce
            let limbs = NSBezierPath()
            limbs.lineWidth = 1.7
            limbs.lineCapStyle = .round
            limbs.lineJoinStyle = .round
            for side in [CGFloat(-1), CGFloat(1)] {
                let swing = side * pose.stride
                let lift = max(0, side * pose.step) * 2.25
                let hip = NSPoint(x: 8.6 + side * 1.1, y: 5.8 + bounce)
                let foot = NSPoint(x: hip.x + swing * 4.2, y: 1.25 + lift)
                limbs.move(to: hip)
                limbs.line(to: NSPoint(x: (hip.x + foot.x) * 0.5 + lift * 0.5, y: 3.75 + lift * 0.55))
                limbs.line(to: foot)
                limbs.line(to: NSPoint(x: foot.x + 1.1, y: foot.y))

                let shoulder = NSPoint(x: 8.9 + side * 1.85, y: 9 + bounce)
                let hand = NSPoint(x: shoulder.x - swing * 3.6, y: 6.2 + bounce + abs(swing) * 0.8)
                limbs.move(to: shoulder)
                limbs.line(to: hand)
            }
            limbs.stroke()

            NSBezierPath(roundedRect: NSRect(x: 6.4, y: 5.5 + bounce, width: 4.8, height: 4.3),
                         xRadius: 1.45, yRadius: 1.45).fill()
            let head = NSBezierPath(roundedRect: NSRect(x: 5.85, y: 9.45 + bounce, width: 7.8, height: 5.15),
                                    xRadius: 1.55, yRadius: 1.55)
            head.windingRule = .evenOdd
            for eyeX in [CGFloat(8.3), CGFloat(11.15)] {
                head.appendOval(in: NSRect(x: eyeX, y: 11.1 + bounce, width: 1.5, height: 1.65))
            }
            head.fill()
            NSBezierPath(rect: NSRect(x: 9.3, y: 14.45 + bounce, width: 0.9, height: 1.15)).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.95, y: 14.9 + bounce, width: 1.6, height: 1.4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
