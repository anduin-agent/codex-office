import AppKit
import Foundation
import OSLog
import ServiceManagement
import WebKit

private func autoReceiptKey(coordinatorID: String, threadID: String) -> String? {
    guard let coordinator = UUID(uuidString: coordinatorID),
          let executor = UUID(uuidString: threadID),
          coordinator != executor
    else { return nil }
    return "\(coordinator.uuidString.lowercased())|\(executor.uuidString.lowercased())"
}

private struct ActivitySnapshot {
    var payload: [String: Any]
    let sourceStatus: String
    let runningRoots: Int?
    let waitingRoots: Int
    let autoReceiptKeys: Set<String>

    init?(data: Data) {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sourceStatus = payload["source_status"] as? String,
              ["ok", "partial", "unavailable"].contains(sourceStatus),
              payload["collected_at"] is String,
              payload["projects"] is [[String: Any]],
              let threads = payload["threads"] as? [[String: Any]]
        else { return nil }
        self.payload = payload
        self.sourceStatus = sourceStatus
        let roots = threads.filter { thread in
            (thread["parent_id"] ?? NSNull()) is NSNull &&
                (thread["root_id"] as? String ?? thread["id"] as? String) == (thread["id"] as? String)
        }
        let workingTeams = Set(threads.compactMap { thread -> String? in
            guard let id = thread["id"] as? String, let root = thread["root_id"] as? String, id != root,
                  let status = thread["status"] as? String, status == "running" || status == "waiting"
            else { return nil }
            return root
        })
        runningRoots = sourceStatus == "unavailable" ? nil : roots.count { thread in
            let status = thread["status"] as? String
            return status != "waiting" && (status == "running" || workingTeams.contains(thread["id"] as? String ?? ""))
        }
        waitingRoots = sourceStatus == "unavailable" ? 0 : roots.count { $0["status"] as? String == "waiting" }
        let coordination = payload["coordination"] as? [String: Any]
        let groups = coordination?["groups"] as? [[String: Any]] ?? []
        var receiptKeys = Set<String>()
        for group in groups {
            guard let coordinatorID = group["coordinator_id"] as? String,
                  let executors = group["executors"] as? [[String: Any]]
            else { continue }
            for executor in executors {
                guard executor["received"] as? Bool == false,
                      let dispatchedAt = executor["dispatched_at"] as? String, !dispatchedAt.isEmpty,
                      let threadID = executor["thread_id"] as? String,
                      let key = autoReceiptKey(coordinatorID: coordinatorID, threadID: threadID)
                else { continue }
                receiptKeys.insert(key)
            }
        }
        autoReceiptKeys = receiptKeys
    }

    init() {
        sourceStatus = "unavailable"
        runningRoots = nil
        waitingRoots = 0
        autoReceiptKeys = []
        payload = [
            "source_status": sourceStatus,
            "collected_at": ISO8601DateFormatter().string(from: Date()),
            "projects": [],
            "threads": [],
        ]
    }
}

private struct Collaboration: Codable {
    struct Executor: Codable {
        let thread_id: UUID
        let received: Bool
    }

    let coordinator_id: UUID
    let executors: [Executor]
    let dispatched_at: String?

    var isValid: Bool {
        let ids = Set(executors.map(\.thread_id))
        guard ids.count >= 2, ids.count == executors.count, !ids.contains(coordinator_id) else { return false }
        guard let dispatched_at else { return true }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: dispatched_at) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: dispatched_at) != nil
    }

    var payload: [String: Any] {
        var result: [String: Any] = [
            "coordinator_id": coordinator_id.uuidString.lowercased(),
            "executors": executors.map {
                ["thread_id": $0.thread_id.uuidString.lowercased(), "received": $0.received]
            },
        ]
        result["dispatched_at"] = dispatched_at
        return result
    }
}

@MainActor
private final class OfficePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class OfficeApplication: NSObject, NSApplicationDelegate, NSWindowDelegate,
    WKNavigationDelegate, WKScriptMessageHandler
{
    private let sceneURL: URL
    private let activityCollector: OfficeActivityCollector
    private let usageCollector: OfficeUsageCollector
    private let defaults = UserDefaults.standard
    private let collaborationKey = "officeCollaboration"
    private let autoReceiptsKey = "officeAutoReceipts"
    private let autoReceiptLimit = 4096
    private var window: NSPanel!
    private var webView: WKWebView!
    private var usageDetailWindow: UsageDetailWindow?
    private var chrome: OfficeChrome!
    private var statusItem: NSStatusItem!
    private var statusTitle = ""
    private let statusMenu = NSMenu()
    private let menuLog = Logger(subsystem: "local.codex-office", category: "MenuBar")
    private var activityItem: NSMenuItem!
    private var metricItem: NSMenuItem!
    private var usageItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var menuBarMetric = MenuBarMetric.tokenSpeed
    private var languagePreference: OfficeLanguage
    private var language: OfficeLanguage
    private var tokenMeter: TokenMeter?
    private var windowItem: NSMenuItem!
    private var pollTask: Task<Void, Never>?
    private var usagePollTask: Task<Void, Never>?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var settingsTask: Task<Void, Never>?
    private var projectDirectoriesTask: Task<Void, Never>?
    private var projectDirectoryPanel: NSOpenPanel?
    private var releaseTask: Task<Void, Never>?
    private var newerReleaseFound = false
    private let releaseCheck = OfficeReleaseCheck(repository: Bundle.main.object(forInfoDictionaryKey: "OfficeReleaseRepository") as? String)
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let sourceRevision = Bundle.main.object(forInfoDictionaryKey: "OfficeSourceRevision") as? String ?? ""
    #if OFFICE_UI_TEST
    private var testLoginEnabled = false
    var offscreenProjectDirectoryPicker: ((String?) -> URL?)?
    #endif
    private var pendingPanelAction: OfficeToolbarAction?
    private var snapshot: ActivitySnapshot?
    private var usage: TokenUsageSnapshot?
    private var usageLoaded = false
    private var showingUsage = false
    private var usageDayTask: Task<Void, Never>?
    private var collaboration: Collaboration?
    private var autoReceipts: [String: Bool] = [:]
    private var sceneReady = false

    init(sceneURL: URL,
         codexHome: String? = UserDefaults.standard.string(forKey: "officeCodexHome"),
         configFile: String? = UserDefaults.standard.string(forKey: "officeConfigFile")) {
        self.sceneURL = sceneURL.standardizedFileURL
        let home = OfficeCollectorPaths.codexHome(codexHome)
        let settings = OfficeCollectorPaths.settings(configFile)
        let preference = settings.preferredLanguage()
        languagePreference = preference
        language = preference.resolved
        activityCollector = OfficeActivityCollector(home: home, settings: settings)
        let seed = sceneURL.deletingLastPathComponent().appendingPathComponent("office-prices.json")
        #if OFFICE_UI_TEST
        let priceCache: URL? = nil
        #else
        let priceCache: URL? = settings.url.deletingLastPathComponent().appendingPathComponent("office-prices.json")
        #endif
        usageCollector = OfficeUsageCollector(home: home, prices: OfficePriceCache(seedURL: seed, cacheURL: priceCache),
                                              settings: settings)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let saved = defaults.data(forKey: collaborationKey),
           let decoded = try? JSONDecoder().decode(Collaboration.self, from: saved),
           decoded.isValid {
            collaboration = decoded
        }
        if let saved = defaults.dictionary(forKey: autoReceiptsKey) as? [String: Bool] {
            for (key, received) in saved where received {
                let ids = key.split(separator: "|", omittingEmptySubsequences: false)
                guard ids.count == 2,
                      key == autoReceiptKey(coordinatorID: String(ids[0]), threadID: String(ids[1]))
                else { continue }
                autoReceipts[key] = true
                if autoReceipts.count == autoReceiptLimit { break }
            }
        }
        createMenu()
        createWindow()
        refreshMenu()
        loadScene()
        pollTask = Self.poll { [weak self] in await self?.refreshActivity() }
        usagePollTask = Self.poll { [weak self] in await self?.refreshUsage() }
    }

    private static func poll(_ refresh: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task {
            let interval: UInt64 = 2_000_000_000
            while !Task.isCancelled {
                let started = DispatchTime.now().uptimeNanoseconds
                await refresh()
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                do {
                    try await Task.sleep(nanoseconds: interval - min(elapsed, interval))
                } catch {
                    break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        usagePollTask?.cancel()
        usageDayTask?.cancel()
        usageDetailWindow?.stop()
        settingsTask?.cancel()
        projectDirectoriesTask?.cancel()
        releaseTask?.cancel()
        tokenMeter?.stop()
        stopClickMonitors()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "office")
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CodexOffice"
        if let button = statusItem.button {
            tokenMeter = TokenMeter(button: button)
            button.imagePosition = .imageLeft
            button.setAccessibilityLabel("Codex Office")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        createMenuItems()
    }

    private func createMenuItems() {
        statusMenu.autoenablesItems = false
        activityItem = statusMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        activityItem.isEnabled = false
        metricItem = statusMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        metricItem.isEnabled = false
        windowItem = statusMenu.addItem(withTitle: "", action: #selector(toggleWindow), keyEquivalent: "")
        windowItem.target = self
        usageItem = statusMenu.addItem(withTitle: "", action: #selector(openUsage), keyEquivalent: "")
        usageItem.target = self
        settingsItem = statusMenu.addItem(withTitle: "", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(.separator())
        quitItem = statusMenu.addItem(withTitle: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        updateStaticMenuTitles()
    }

    private func updateStaticMenuTitles() {
        usageItem?.title = language.text("用量统计…", "Usage…")
        settingsItem?.title = language.text("设置…", "Settings…")
        quitItem?.title = language.text("退出 Codex Office", "Quit Codex Office")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            menuLog.debug("Opening menu bar context menu")
            refreshMenu()
            // Attach the menu only while AppKit presents it, so normal clicks still invoke this action.
            statusItem.menu = statusMenu
            defer { statusItem.menu = nil }
            statusItem.button?.performClick(nil)
        } else {
            // Leave the menu bar's click tracking before ordering the office window.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toggleWindow()
                self.menuLog.debug("Menu bar click: office visible = \(self.windowVisible, privacy: .public)")
            }
        }
    }

    private func createWindow(preferLiquidGlass: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "office")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 13
        webView.layer?.masksToBounds = true
        chrome = OfficeChrome(scene: webView, target: self, action: #selector(performToolbarAction(_:)),
                              preferLiquidGlass: preferLiquidGlass, language: language)

        window = OfficePanel(
            contentRect: NSRect(origin: .zero, size: OfficeChrome.preferredPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Office"
        // Size the chrome from the panel instead of fitting the panel to its views.
        let content = NSView(frame: NSRect(origin: .zero, size: OfficeChrome.preferredPanelSize))
        content.autoresizesSubviews = false
        window.contentView = content
        content.addSubview(chrome)
        sizeChromeToPanel()
        window.delegate = self
        window.level = .popUpMenu
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
    }

    private var windowVisible: Bool {
        window.isVisible && !NSApp.isHidden
    }

    private func sizeChromeToPanel() {
        let size = window.contentRect(forFrameRect: window.frame).size
        chrome.frame = NSRect(origin: .zero, size: size)
    }

    private func refreshMenu() {
        guard activityItem != nil else { return }
        let waiting = snapshot?.waitingRoots ?? 0
        let count = snapshot?.runningRoots
        let status: String
        if let count {
            let running = language.text("进行中的主会话 \(count) 个", "\(count) active \(count == 1 ? "chat" : "chats")")
            let attention = waiting > 0 ? language.text(" · 待确认 \(waiting) 个", " · \(waiting) waiting") : ""
            let partial = snapshot?.sourceStatus == "partial" ? language.text(" · 数据不完整", " · Partial data") : ""
            status = running + attention + partial
        } else {
            status = snapshot == nil
                ? language.text("正在读取活动", "Loading activity")
                : language.text("活动数据不可用", "Activity unavailable")
        }
        activityItem.title = status
        let metricStatus = usage?.description(for: menuBarMetric, language: language) ?? (usageLoaded
            ? language.text("用量不可用", "Usage unavailable")
            : language.text("正在读取 token 用量", "Loading token usage"))
        metricItem.title = metricStatus
        let countLabel = waiting > 0
            ? language.text("等你确认 \(waiting)", "\(waiting) Waiting")
            : (count.map(String.init) ?? "—") + language.text(" 进行中", " Active")
        let metricLabel = usage?.title(for: menuBarMetric, language: language) ?? "—"
        let title = countLabel + " · " + metricLabel
        let button = statusItem?.button
        if statusTitle != title {
            if let button {
                let size = button.font?.pointSize ?? NSFont.systemFontSize
                let label = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: size)])
                label.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                                   range: NSRange(location: 0, length: (countLabel as NSString).length))
                button.attributedTitle = label
            }
            statusTitle = title
        }
        let description = "Codex Office · \(metricStatus) · \(status)"
        button?.toolTip = description
        button?.setAccessibilityLabel(description)
        windowItem.title = windowVisible ? language.text("隐藏办公室", "Hide Office") : language.text("显示办公室", "Show Office")
    }

    @objc private func openSettings() {
        openPanelDialog(.settings)
    }

    @objc private func openUsage() {
        openPanelDialog(.usage)
    }

    private func openPanelDialog(_ action: OfficeToolbarAction) {
        // Let the contextual menu finish tracking before showing the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.windowVisible { self.showWindow() }
            self.pendingPanelAction = action
            self.performPanelActionIfReady()
        }
    }

    @objc private func performToolbarAction(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let action = OfficeToolbarAction(rawValue: name) else { return }
        pendingPanelAction = action
        performPanelActionIfReady()
    }

    private func performPanelActionIfReady() {
        guard sceneReady, let action = pendingPanelAction else { return }
        pendingPanelAction = nil
        if windowVisible { window.makeFirstResponder(webView) }
        webView.evaluateJavaScript(action.function)
    }

    @objc private func toggleWindow() {
        guard projectDirectoryPanel == nil else { return }
        if windowVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private var statusButtonFrame: NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func showWindow() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        let anchor = statusButtonFrame
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main
        if let screen {
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 6)
            let top = min(bounds.maxY, (anchor?.minY ?? bounds.maxY + 6) - 6)
            let preferredSize = OfficeChrome.preferredPanelSize
            let width = min(preferredSize.width, bounds.width)
            let height = min(preferredSize.height, max(1, top - bounds.minY))
            let center = anchor?.midX ?? bounds.maxX
            let left = min(max(bounds.minX, center - width / 2), bounds.maxX - width)
            window.setFrame(NSRect(x: left, y: top - height, width: width, height: height), display: true)
        }
        sizeChromeToPanel()
        window.orderFrontRegardless()
        window.makeKey()
        startClickMonitors()
        syncVisibility()
    }

    private func hideWindow() {
        projectDirectoryPanel?.cancel(nil)
        window.orderOut(nil)
        stopClickMonitors()
        syncVisibility()
    }

    private func startClickMonitors() {
        stopClickMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissForOutsideClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissForOutsideClick() }
            return event
        }
    }

    private func stopClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    private func dismissForOutsideClick() {
        let mouse = NSEvent.mouseLocation
        guard projectDirectoryPanel == nil, windowVisible, !window.frame.contains(mouse),
              statusButtonFrame?.contains(mouse) != true else { return }
        hideWindow()
        menuLog.debug("Dismissed office panel after an outside click")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        menuLog.debug("Office on screen = \(self.window.occlusionState.contains(.visible), privacy: .public)")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    func applicationDidHide(_ notification: Notification) {
        hideWindow()
    }

    func applicationDidUnhide(_ notification: Notification) {
        syncVisibility()
    }

    private func loadScene() {
        sceneReady = false
        chrome.setReady(false)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: "window.officeNativeToolbar = true; window.officeInitialLanguage = '\(language.rawValue)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        webView.loadFileURL(sceneURL, allowingReadAccessTo: sceneURL.deletingLastPathComponent())
    }

    private func isSceneURL(_ url: URL?) -> Bool {
        url?.standardizedFileURL == sceneURL
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && isSceneURL(navigationAction.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markSceneReady()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadScene()
    }

    private func markSceneReady() {
        guard !sceneReady else { return }
        sceneReady = true
        chrome.setReady(true)
        pushLanguage()
        syncVisibility()
        performPanelActionIfReady()
    }

    private func syncVisibility() {
        refreshMenu()
        guard sceneReady else { return }
        pushSnapshot()
        pushUsage()
        if windowVisible { pushAppSettings() }
        webView.callAsyncJavaScript(
            "window.officeSetVisible(visible);",
            arguments: ["visible": windowVisible],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    private func refreshActivity() async {
        let result = (try? await activityCollector.snapshot()).flatMap(ActivitySnapshot.init(data:))
        guard !Task.isCancelled else { return }
        snapshot = result ?? ActivitySnapshot()
        applyMenuBarMetric(result?.payload["menu_bar_metric"])
        if applyOfficeLanguage() { pushLanguage() }
        refreshMenu()
        pushSnapshot()
    }

    private func refreshUsage() async {
        let result = (try? await usageCollector.snapshot(refreshPrices: windowVisible))
            .flatMap(TokenUsageSnapshot.init(data:))
        guard !Task.isCancelled else { return }
        usage = result
        usageLoaded = true
        tokenMeter?.update(rate: result?.tokensPerMinute)
        refreshMenu()
        pushUsage()
    }

    private func pushUsage() {
        guard sceneReady, windowVisible, usageLoaded else { return }
        var payload = usage?.payload
        if var recent = payload?["recent"] as? [[String: Any]], !recent.isEmpty,
           let threads = snapshot?.payload["threads"] as? [[String: Any]] {
            let ids = Set(recent.compactMap { $0["id"] as? String })
            var threadByID: [String: OfficeJSON] = [:]
            for thread in threads {
                if let id = thread["id"] as? String, ids.contains(id) { threadByID[id] = thread }
            }
            for index in recent.indices {
                if let id = recent[index]["id"] as? String, let thread = threadByID[id] {
                    recent[index]["title"] = thread["title"]
                    recent[index]["title_kind"] = thread["title_kind"]
                }
            }
            payload?["recent"] = recent
        }
        webView.callAsyncJavaScript(
            "window.officeSetUsage(usage);", arguments: ["usage": payload as Any? ?? NSNull()],
            in: nil, in: .page, completionHandler: nil
        )
    }

    private func pushSnapshot() {
        guard sceneReady, windowVisible, let snapshot else { return }
        webView.callAsyncJavaScript(
            "window.officeSetSnapshot(snapshot, collaboration, autoReceipts);",
            arguments: [
                "snapshot": snapshot.payload,
                "collaboration": collaboration?.payload as Any? ?? NSNull(),
                "autoReceipts": autoReceipts.filter { snapshot.autoReceiptKeys.contains($0.key) },
            ],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "office",
              message.frameInfo.isMainFrame,
              isSceneURL(message.frameInfo.request.url),
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        switch action {
        case "ready":
            markSceneReady()
        case "toolbarState":
            chrome.update(body)
            showingUsage = body["view"] as? String == "usage"
            if !showingUsage { usageDayTask?.cancel() }
        case "usageDay":
            if showingUsage, let day = body["day"] as? String, day.utf8.count == 10,
               let request = body["request"] as? Int, request > 0 {
                requestUsageDay(day, request: request)
            }
        case "openUsageDetails":
            showUsageDetails()
        case "openChat":
            if let id = body["id"] as? String {
                openChat(id)
            }
        case "saveCollaboration":
            if let value = body["collaboration"] {
                saveCollaboration(value)
            }
        case "saveAutoReceipt":
            saveAutoReceipt(body)
        case "loadSettings":
            requestOfficeSettings(nil)
        case "loadProjectDirectories":
            requestProjectDirectories()
        case "chooseProjectDirectory":
            if let request = body["request"] as? Int, request > 0 {
                chooseProjectDirectory(request: request, currentPath: body["path"] as? String)
            }
        case "loadAppSettings":
            pushAppSettings()
        case "setLoginItem":
            if let enabled = body["enabled"] as? Bool { setLoginItem(enabled) }
        case "openLoginItems":
            #if !OFFICE_UI_TEST
            if #available(macOS 13.0, *), loginItemStatus == "approval" {
                SMAppService.openSystemSettingsLoginItems()
            }
            #endif
        case "checkUpdate":
            checkUpdate()
        case "openRelease":
            #if !OFFICE_UI_TEST
            if newerReleaseFound, let releaseCheck { NSWorkspace.shared.open(releaseCheck.releasesPage) }
            #endif
        case "saveSettings":
            if let changes = body["changes"] as? [String: Any],
               Set(changes.keys).isSubset(of: OfficeSettings.editableKeys) {
                requestOfficeSettings(changes)
            }
        default:
            break
        }
    }

    private func requestUsageDay(_ day: String, request: Int) {
        usageDayTask?.cancel()
        let language = self.language
        usageDayTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let data = try? await self.usageCollector.dayDetails(day, language: language)
            guard !Task.isCancelled, self.showingUsage else { return }
            let details = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? OfficeJSON
                ?? ["day": day, "unavailable": true]
            self.webView.callAsyncJavaScript(
                "window.officeReceiveUsageDay(details, request);",
                arguments: ["details": details, "request": request], in: nil, in: .page, completionHandler: nil
            )
        }
    }

    private var loginItemStatus: String {
        #if OFFICE_UI_TEST
        return testLoginEnabled ? "on" : "off"
        #else
        guard #available(macOS 13.0, *) else { return "unsupported" }
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "approval"
        case .notRegistered: return "off"
        case .notFound: return "unavailable"
        @unknown default: return "unavailable"
        }
        #endif
    }

    private func setLoginItem(_ enabled: Bool) {
        #if OFFICE_UI_TEST
        testLoginEnabled = enabled
        pushAppSettings()
        #else
        guard #available(macOS 13.0, *) else { return pushAppSettings() }
        let service = SMAppService.mainApp
        do {
            if enabled && service.status == .notRegistered {
                try service.register()
            } else if !enabled && (service.status == .enabled || service.status == .requiresApproval) {
                try service.unregister()
            }
            pushAppSettings()
        } catch {
            pushAppSettings(loginFailed: true)
        }
        #endif
    }

    private func pushAppSettings(loginFailed: Bool = false) {
        guard sceneReady else { return }
        #if OFFICE_UI_TEST
        let version = "0.1.0", revision = "a1b2c3d4"
        #else
        let version = appVersion, revision = sourceRevision
        #endif
        webView.callAsyncJavaScript("window.officeReceiveAppSettings(settings);",
            arguments: ["settings": ["version": version, "revision": revision, "login": loginItemStatus,
                                      "loginFailed": loginFailed]], in: nil, in: .page, completionHandler: nil)
    }

    private func checkUpdate() {
        guard releaseTask == nil else { return }
        newerReleaseFound = false
        #if OFFICE_UI_TEST
        pushReleaseResult("unconfigured")
        #else
        guard let releaseCheck else { return pushReleaseResult("unconfigured") }
        releaseTask = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseTask = nil }
            let (result, version) = await releaseCheck.check(currentVersion: self.appVersion)
            guard !Task.isCancelled else { return }
            self.newerReleaseFound = result == .available
            self.pushReleaseResult(result.rawValue, version: version ?? "")
        }
        #endif
    }

    private func pushReleaseResult(_ result: String, version: String = "") {
        webView.callAsyncJavaScript("window.officeReceiveUpdate(result, version);",
            arguments: ["result": result, "version": version], in: nil, in: .page, completionHandler: nil)
    }

    private func applyMenuBarMetric(_ value: Any?) {
        guard let value = value as? String, let metric = MenuBarMetric(rawValue: value) else { return }
        menuBarMetric = metric
    }

    private func showUsageDetails() {
        let screen = window.screen
        if usageDetailWindow == nil {
            let resource = sceneURL.deletingLastPathComponent().appendingPathComponent("usage-detail.html")
            usageDetailWindow = UsageDetailWindow(sceneURL: resource, collector: usageCollector, language: language) {
                [weak self] id, parent in self?.openChat(id, from: parent)
            }
        }
        hideWindow()
        usageDetailWindow?.show(on: screen)
    }

    @discardableResult
    private func applyOfficeLanguage(_ value: Any? = nil) -> Bool {
        if let raw = value as? String, let preference = OfficeLanguage(rawValue: raw) {
            languagePreference = preference
        }
        let resolved = languagePreference.resolved
        guard resolved != language else { return false }
        language = resolved
        chrome?.setLanguage(resolved)
        usageDetailWindow?.setLanguage(resolved)
        updateStaticMenuTitles()
        return true
    }

    private func pushLanguage() {
        guard sceneReady else { return }
        webView.callAsyncJavaScript(
            "window.officeSetLanguage?.(language);",
            arguments: ["language": language.rawValue],
            in: nil, in: .page, completionHandler: nil
        )
    }

    private func requestOfficeSettings(_ changes: [String: Any]?) {
        guard settingsTask == nil else { return }
        settingsTask = Task { [weak self] in
            guard let self else { return }
            defer { self.settingsTask = nil }
            do {
                let body = try changes.map { try JSONSerialization.data(withJSONObject: $0) }
                let data = try await self.activityCollector.officeSettings(changes: body)
                guard !Task.isCancelled else { return }
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let office = payload?["office"] as? [String: Any] {
                    self.applyMenuBarMetric(office["menu_bar_metric"])
                    self.applyOfficeLanguage(office["language"])
                    self.snapshot?.payload["visible_sections"] = office["visible_sections"]
                    if let changes, changes.keys.contains(where: { ["coordination_section", "projects", "thread_projects"].contains($0) }) {
                        await self.refreshActivity()
                    }
                    self.refreshMenu()
                    self.reportSettings(office, error: nil, saved: changes != nil,
                                        sidebar: payload?["sidebar"] as? [String: Any])
                    self.menuLog.debug("Office settings request succeeded (saved = \(changes != nil, privacy: .public))")
                } else {
                    self.reportSettings(nil, error: .init("本机设置不可用。", "Local settings are unavailable."), saved: false)
                }
            } catch {
                if !Task.isCancelled {
                    let message = (error as? OfficeSettings.InvalidSettings)
                        ?? .init("无法访问本机设置，请检查文件权限。", "Could not access local settings. Check file permissions.")
                    self.reportSettings(nil, error: message, saved: false)
                }
            }
        }
    }

    private func reportSettings(_ office: OfficeJSON?, error: OfficeSettings.InvalidSettings?, saved: Bool, sidebar: OfficeJSON? = nil) {
        let messages = error.map { ["zh-CN": $0.chinese, "en": $0.english] }
        webView.callAsyncJavaScript(
            "window.officeSetLanguage?.(language); window.officeReceiveSettings(office, error, saved, sidebar);",
            arguments: ["office": office as Any? ?? NSNull(), "error": messages as Any? ?? NSNull(),
                        "saved": saved, "sidebar": sidebar as Any? ?? NSNull(), "language": language.rawValue],
            in: nil, in: .page, completionHandler: nil
        )
    }

    private func requestProjectDirectories() {
        guard projectDirectoriesTask == nil else { return }
        projectDirectoriesTask = Task { [weak self] in
            guard let self else { return }
            defer { self.projectDirectoriesTask = nil }
            let directories = await self.activityCollector.projectDirectories()
            guard !Task.isCancelled else { return }
            self.webView.callAsyncJavaScript(
                "window.officeReceiveProjectDirectories(directories);",
                arguments: ["directories": directories], in: nil, in: .page, completionHandler: nil
            )
        }
    }

    private func chooseProjectDirectory(request: Int, currentPath: String?) {
        #if OFFICE_UI_TEST
        reportProjectDirectory(offscreenProjectDirectoryPicker?(currentPath), request: request)
        #else
        guard windowVisible, window.attachedSheet == nil, projectDirectoryPanel == nil else {
            reportProjectDirectory(nil, request: request)
            return
        }
        let panel = NSOpenPanel()
        panel.title = language.text("选择项目目录", "Choose project folder")
        panel.prompt = language.text("选择", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let currentPath, officeValidText(currentPath, limit: 4096), currentPath.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        }
        projectDirectoryPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.projectDirectoryPanel = nil
            self.reportProjectDirectory(response == .OK ? panel?.url : nil, request: request)
        }
        #endif
    }

    private func reportProjectDirectory(_ url: URL?, request: Int) {
        let path = officeCanonicalPath(url?.path).flatMap { officeValidText($0, limit: 4096) ? $0 : nil }
        webView.callAsyncJavaScript(
            "window.officeReceiveProjectDirectory(path, request);",
            arguments: ["path": path as Any? ?? NSNull(), "request": request], in: nil, in: .page, completionHandler: nil
        )
    }

    private func openChat(_ id: String, from parent: NSWindow? = nil) {
        guard let uuid = UUID(uuidString: id),
              let url = URL(string: "codex://threads/\(uuid.uuidString.lowercased())")
        else { return }
        if NSWorkspace.shared.open(url) {
            if parent == nil { hideWindow() }
        } else if let owner = parent ?? window, owner.attachedSheet == nil {
            let alert = NSAlert()
            alert.messageText = language.text("无法打开 Codex 聊天", "Could not open the Codex chat")
            alert.informativeText = language.text("请确认本机的 Codex 客户端支持聊天链接。", "Check that your local Codex app supports chat links.")
            alert.addButton(withTitle: language.text("好", "OK"))
            alert.beginSheetModal(for: owner)
        }
    }

    private func saveCollaboration(_ value: Any) {
        if value is NSNull {
            collaboration = nil
            defaults.removeObject(forKey: collaborationKey)
        } else if value is [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let decoded = try? JSONDecoder().decode(Collaboration.self, from: data),
                  decoded.isValid,
                  let encoded = try? JSONEncoder().encode(decoded) {
            collaboration = decoded
            defaults.set(encoded, forKey: collaborationKey)
        }
        pushSnapshot()
    }

    private func saveAutoReceipt(_ body: [String: Any]) {
        guard let coordinatorID = body["coordinator_id"] as? String,
              let threadID = body["thread_id"] as? String,
              let key = autoReceiptKey(coordinatorID: coordinatorID, threadID: threadID),
              let currentKeys = snapshot?.autoReceiptKeys,
              currentKeys.contains(key),
              autoReceipts[key] == nil
        else { return }

        if autoReceipts.count == autoReceiptLimit {
            guard let previous = autoReceipts.keys.first(where: { !currentKeys.contains($0) }) else { return }
            autoReceipts.removeValue(forKey: previous)
        }
        autoReceipts[key] = true
        defaults.set(autoReceipts, forKey: autoReceiptsKey)
        pushSnapshot()
    }
}

#if OFFICE_UI_TEST
extension OfficeApplication {
    func primeOffscreenUsage() async throws {
        _ = try await usageCollector.snapshot(refreshPrices: false)
    }

    func loadOffscreenPanel(preferLiquidGlass: Bool = true) -> (NSPanel, WKWebView) {
        createWindow(preferLiquidGlass: preferLiquidGlass)
        createMenuItems()
        loadScene()
        return (window, webView)
    }

    func setOffscreenMenuUsage(_ data: Data) {
        usage = TokenUsageSnapshot(data: data)
        refreshMenu()
    }

    var offscreenMenuBar: (title: String, items: [String]) {
        (statusTitle, statusMenu.items.filter { !$0.isSeparatorItem }.map(\.title))
    }

    func stopOffscreenPanel() {
        usageDetailWindow?.stop()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "office")
    }

    var offscreenUsageDetails: (NSWindow, WKWebView)? {
        usageDetailWindow.map { ($0.window, $0.webView) }
    }
}
#else
@main
struct CodexOffice {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--import-settings" {
            importSettings(arguments)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let sceneURL = Bundle.main.url(forResource: "office", withExtension: "html")
        else {
            let language = OfficeCollectorPaths.settings().preferredLanguage()
            let alert = NSAlert()
            alert.messageText = language.text("无法加载 Codex Office", "Could not load Codex Office")
            alert.informativeText = language.text("应用包缺少办公室资源，请重新构建。", "The app is missing its office resources. Rebuild the app.")
            alert.addButton(withTitle: language.text("好", "OK"))
            alert.runModal()
            return
        }
        let delegate = OfficeApplication(sceneURL: sceneURL)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private static func importSettings(_ arguments: [String]) {
        guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--config") else {
            FileHandle.standardError.write(Data("用法：CodexOffice --import-settings <源文件> [--config <目标文件>]\n".utf8))
            exit(EXIT_FAILURE)
        }
        let settings = OfficeCollectorPaths.settings(arguments.count == 4 ? arguments[3] : nil)
        do {
            try settings.importFrom(OfficeCollectorPaths.fileURL(arguments[1]))
        } catch {
            let language = settings.preferredLanguage()
            let message = (error as? OfficeSettings.InvalidSettings)?.message(in: language)
                ?? language.text("无法读取或导入办公室设置。", "Could not read or import office settings.")
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}
#endif
