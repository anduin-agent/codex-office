import AppKit

enum OfficeToolbarAction: String {
    case waiting
    case collaboration
    case usage
    case settings

    func title(in language: OfficeLanguage) -> String {
        switch self {
        case .waiting: language.text("待确认", "Waiting")
        case .collaboration: language.text("跨项目协作", "Collaboration")
        case .usage: language.text("用量", "Usage")
        case .settings: language.text("办公室设置", "Office Settings")
        }
    }

    var function: String {
        switch self {
        case .waiting: "window.officeLocateWaiting()"
        case .collaboration: "window.officeOpenCollaboration()"
        case .usage: "window.officeOpenUsage()"
        case .settings: "window.officeOpenSettings()"
        }
    }
}

@MainActor
private final class OfficeToolbarButton: NSButton {
    static let height: CGFloat = 32
    static let iconWidth: CGFloat = 45
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    var drawsAttention = false

    override var intrinsicContentSize: NSSize {
        let content = super.intrinsicContentSize
        return NSSize(width: imagePosition == .imageOnly ? Self.iconWidth : content.width + 20, height: Self.height)
    }

    // AppKit's image-only inset would otherwise make the settings button 5pt taller.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let innerBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = innerBounds.height / 2
        let outline = NSBezierPath(roundedRect: innerBounds, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        let color = drawsAttention ? NSColor.systemOrange : NSColor.labelColor
        let (fill, stroke): (CGFloat, CGFloat)
        if !isEnabled { (fill, stroke) = (0.04, 0.10) }
        else if isHighlighted { (fill, stroke) = (0.18, drawsAttention ? 0.58 : 0.36) }
        else if hovering { (fill, stroke) = (0.12, drawsAttention ? 0.52 : 0.30) }
        else { (fill, stroke) = drawsAttention ? (0.11, 0.44) : (0.07, 0.24) }
        color.withAlphaComponent(fill).setFill()
        outline.fill()
        color.withAlphaComponent(stroke).setStroke()
        outline.stroke()
        super.draw(dirtyRect)
    }
}

@MainActor
private final class OfficeToolbar: NSView {
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    let title = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    private var actions: [OfficeToolbarButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Self.titleFont
        status.font = .systemFont(ofSize: 11)
        // The toolbar owns its child frames; its parent constraints set its width.
        autoresizesSubviews = false
        for label in [title, status] {
            label.usesSingleLineMode = true
            addSubview(label)
        }
        title.lineBreakMode = .byClipping
        status.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { nil }

    func append(_ button: OfficeToolbarButton) {
        actions.append(button)
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let buttons = actions.filter { !$0.isHidden }
        guard !buttons.isEmpty else { return }
        let inset = min(14, bounds.width / 24)
        let gap = min(10, bounds.width / 40)
        let textWidth = (title.stringValue as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let titleWidth = ceil(max(textWidth, title.intrinsicContentSize.width)) + 8
        let available = max(0, bounds.width - 2 * inset - gap * CGFloat(buttons.count) - titleWidth)
        let preferred = buttons.map { ceil($0.intrinsicContentSize.width) }
        let iconWidth = OfficeToolbarButton.iconWidth
        let iconSpace = min(iconWidth, available)
        let minimum = min(iconWidth, (available - iconSpace) / CGFloat(max(1, buttons.count - 1)))
        let minimums = buttons.map { $0.imagePosition == .imageOnly ? iconSpace : minimum }
        let extras = zip(preferred, minimums).map { max(0, $0 - $1) }
        let totalExtra = extras.reduce(0, +)
        let remaining = max(0, available - minimums.reduce(0, +))
        let fraction = totalExtra > 0 ? min(1, remaining / totalExtra) : 0
        var right = bounds.maxX - inset
        for index in buttons.indices.reversed() {
            let button = buttons[index]
            let width = minimums[index] + floor(extras[index] * fraction)
            let height = OfficeToolbarButton.height
            button.frame = NSRect(x: right - width, y: floor(bounds.midY - height / 2), width: width, height: height)
            right -= width + gap
        }

        // The activity label uses the space left after the title and actions.
        let statusX = inset + titleWidth + gap
        place(title, x: inset, width: titleWidth)
        place(status, x: statusX, width: max(0, right - statusX))
    }

    private func place(_ label: NSTextField, x: CGFloat, width: CGFloat) {
        label.isHidden = width < 24
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: floor(bounds.midY - height / 2), width: width, height: height)
    }
}

@MainActor
final class OfficeChrome: NSView {
    static let preferredPanelSize = NSSize(width: 708, height: 620)

    let materialView: NSView
    private let toolbar = OfficeToolbar(frame: .zero)
    private var buttons: [OfficeToolbarAction: OfficeToolbarButton] = [:]
    private var language: OfficeLanguage
    private var waitingCount = 0

    init(scene: NSView, target: AnyObject, action: Selector, preferLiquidGlass: Bool = true,
         language: OfficeLanguage = .simplifiedChinese) {
        self.language = language.resolved
        let content = NSView()
        let radius: CGFloat = 20
        if #available(macOS 26.0, *), preferLiquidGlass {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .clear
            glass.contentView = content
            materialView = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = .popover
            frost.blendingMode = .behindWindow
            frost.state = .active
            frost.addSubview(content)
            materialView = frost
        }
        super.init(frame: NSRect(origin: .zero, size: Self.preferredPanelSize))

        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        addSubview(materialView)
        pin(materialView, to: self)
        pin(content, to: materialView)

        for item: OfficeToolbarAction in [.waiting, .collaboration, .settings] {
            let button = OfficeToolbarButton(frame: .zero)
            button.target = target
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.isEnabled = false
            button.cell?.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            if item == .settings, let icon = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil) {
                let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                button.title = ""
                button.image = icon.withSymbolConfiguration(configuration) ?? icon
                button.imagePosition = .imageOnly
            }
            if item == .waiting {
                button.isHidden = true
                button.drawsAttention = true
            }
            buttons[item] = button
            toolbar.append(button)
        }

        let divider = NSBox()
        divider.boxType = .separator
        for view in [toolbar, divider, scene] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            // Leave the native material visible around the WebKit scene card.
            scene.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scene.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scene.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 3),
            scene.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        updateStaticLabels()
    }

    required init?(coder: NSCoder) { nil }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    func setReady(_ ready: Bool) {
        for button in buttons.values { button.isEnabled = ready }
    }

    func setLanguage(_ language: OfficeLanguage) {
        self.language = language.resolved
        updateStaticLabels()
    }

    private func updateStaticLabels() {
        toolbar.title.stringValue = "Codex Office"
        let status = toolbar.status
        status.stringValue = language.text("等待本机快照", "Waiting for local activity")
        status.toolTip = status.stringValue
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        for (action, button) in buttons {
            let label = action.title(in: language)
            // Updating a titled AppKit button can switch its cell to image-leading.
            if button.imagePosition != .imageOnly { button.title = label }
            button.toolTip = action == .collaboration ? collaborationHelp : label
            button.setAccessibilityLabel(label)
        }
        updateWaitingButton()
        toolbar.needsLayout = true
    }

    private var collaborationHelp: String {
        language.text("查看统筹聊天向其他项目派发的任务和回执",
                      "See tasks dispatched by the coordinator chat and their acknowledgments")
    }

    private func updateWaitingButton() {
        let button = buttons[.waiting]
        button?.title = language.text("\(waitingCount) 个待确认", "\(waitingCount) Waiting")
        button?.toolTip = language.text("依次定位等你确认的聊天", "Find the next chat waiting for you")
        button?.setAccessibilityLabel(language.text("\(waitingCount) 个待确认，依次定位聊天",
                                                    "\(waitingCount) waiting. Find the next chat."))
        button?.isHidden = waitingCount == 0
    }

    func update(_ payload: [String: Any]) {
        guard let source = payload["source"] as? String,
              let sourceStatus = payload["sourceStatus"] as? String,
              let waiting = payload["waitingCount"] as? Int, waiting >= 0,
              let collaboration = payload["collaborationTitle"] as? String else { return }
        let status = toolbar.status
        status.stringValue = source
        status.toolTip = source
        let running = (payload["runningCount"] as? Int ?? 0) > 0
        status.font = .monospacedDigitSystemFont(ofSize: running ? 12 : 11, weight: running ? .semibold : .regular)
        status.textColor = running ? .systemBlue : ["unavailable", "partial"].contains(sourceStatus) ? .systemOrange : .secondaryLabelColor
        waitingCount = waiting
        updateWaitingButton()
        buttons[.collaboration]?.title = collaboration
        buttons[.collaboration]?.toolTip = collaborationHelp
        buttons[.collaboration]?.setAccessibilityLabel(collaboration)
        toolbar.needsLayout = true
    }
}
