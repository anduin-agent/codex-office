import AppKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers
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

private enum PipelineSelection: Equatable {
    case repository(String)
    case workspace(String)
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
    private let codexHome: URL
    private let activityCollector: OfficeActivityCollector
    private let usageCollector: OfficeUsageCollector
    private let pipeline: OfficePipeline
    private let robotSkin: OfficeRobotSkin
    private var robotSkinImages: [Data]
    private var robotSkinRevision = 0
    private var importingRobotSkin = false
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
    private var usageVisibilityTask: Task<Void, Never>?
    private var usageRefreshID = 0
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var settingsTask: Task<Void, Never>?
    private var projectDirectoriesTask: Task<Void, Never>?
    private var pipelineRepositoriesTask: Task<Void, Never>?
    private var pipelineRepositories: [String: [OfficePipelineWorkspace]] = [:]
    private var pipelinePreferences: OfficePipelinePreferences
    private var pipelinePreferenceWrite: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineResult: (request: Int, selection: PipelineSelection, useCLI: Bool, snapshot: OfficePipelineSnapshot)?
    private var filePicker: NSOpenPanel?
    private var releaseTask: Task<Void, Never>?
    private var newerReleaseFound = false
    private let releaseCheck = OfficeReleaseCheck(repository: Bundle.main.object(forInfoDictionaryKey: "OfficeReleaseRepository") as? String)
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let sourceRevision = Bundle.main.object(forInfoDictionaryKey: "OfficeSourceRevision") as? String ?? ""
    #if OFFICE_UI_TEST
    private var testLoginEnabled = false
    var offscreenProjectDirectoryPicker: ((String?) -> URL?)?
    var offscreenRobotSkinPicker: ((Bool) -> [URL])?
    var offscreenPanelBounds: NSRect?
    #endif
    private var pendingPanelAction: OfficeToolbarAction?
    private var snapshot: ActivitySnapshot?
    private var usage: TokenUsageSnapshot?
    private var usageQuotaAccount: String?
    private var liveQuotaEnabled: Bool
    private var liveQuota: OfficeLiveQuota?
    private var liveQuotaTask: Task<Void, Never>?
    private var nextLiveQuotaRead: TimeInterval = 0
    #if OFFICE_UI_TEST
    var offscreenQuotaExecutable: URL?
    var offscreenUsageScope: CodexTokenUsage.Scope = .full
    #endif
    private var usageLoaded = false
    private var usageIncludesDetails = false
    private var showingUsage = false
    private var officeFloorCount = 0
    private var officePreferredSize: NSSize?
    private var officeZoom: Int
    private var showSkinDesks: Bool
    private var usageDayTask: Task<Void, Never>?
    private var collaboration: Collaboration?
    private var autoReceipts: [String: Bool] = [:]
    private var sceneReady = false

    init(sceneURL: URL,
         codexHome: String? = UserDefaults.standard.string(forKey: "officeCodexHome"),
         configFile: String? = UserDefaults.standard.string(forKey: "officeConfigFile"),
         pipeline: OfficePipeline = OfficePipeline()) {
        self.sceneURL = sceneURL.standardizedFileURL
        self.pipeline = pipeline
        let home = OfficeCollectorPaths.codexHome(codexHome)
        let settings = OfficeCollectorPaths.settings(configFile)
        let skin = OfficeRobotSkin(file: settings.url.deletingLastPathComponent().appendingPathComponent("robot-skins.plist"))
        robotSkin = skin
        robotSkinImages = skin.load()
        self.codexHome = home
        let document = try? settings.load()
        pipelinePreferences = OfficePipelinePreferences(document)
        liveQuotaEnabled = document?["live_quota"] as? Bool ?? OfficeSettings.defaultLiveQuota
        officeZoom = document?["office_zoom"] as? Int ?? 100
        showSkinDesks = document?["show_skin_desks"] as? Bool ?? true
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
        usageVisibilityTask?.cancel()
        liveQuotaTask?.cancel()
        usageDayTask?.cancel()
        usageDetailWindow?.stop()
        settingsTask?.cancel()
        projectDirectoriesTask?.cancel()
        closePipeline()
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
        let displayedUsage = menuBarMetric == .planRemaining
            ? usage.map { TokenUsageSnapshot(payload: usagePayload($0.payload)) } : usage
        let metricStatus = displayedUsage?.description(for: menuBarMetric, language: language) ?? (usageLoaded
            ? language.text("用量不可用", "Usage unavailable")
            : language.text("正在读取 token 用量", "Loading token usage"))
        metricItem.title = metricStatus
        let countLabel = waiting > 0
            ? language.text("等你确认 \(waiting)", "\(waiting) Waiting")
            : (count.map(String.init) ?? "—") + language.text(" 进行中", " Active")
        let metricLabel = displayedUsage?.title(for: menuBarMetric, language: language) ?? "—"
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
        guard filePicker == nil else { return }
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
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func positionWindow() {
        let anchor = statusButtonFrame
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main
        var visibleFrame = screen?.visibleFrame
        #if OFFICE_UI_TEST
        if let offscreenPanelBounds { visibleFrame = offscreenPanelBounds }
        #endif
        if let visibleFrame {
            let frame = OfficeChrome.panelFrame(in: visibleFrame, anchor: anchor,
                                               floorCount: showingUsage ? 0 : officeFloorCount,
                                               officeHeight: officePreferredSize?.height,
                                               officeWidth: officePreferredSize?.width)
            if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
        }
        sizeChromeToPanel()
    }

    private func showWindow() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        positionWindow()
        window.orderFrontRegardless()
        window.makeKey()
        startClickMonitors()
        syncVisibility()
    }

    private func hideWindow() {
        filePicker?.cancel(nil)
        closePipeline()
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
        guard filePicker == nil, windowVisible, !window.frame.contains(mouse),
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

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if windowVisible { positionWindow() }
    }

    private func loadScene() {
        closePipeline()
        sceneReady = false
        chrome.setReady(false)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: """
                window.officeNativeToolbar = true;
                window.officePreferredSceneHeight = \(OfficeChrome.preferredSceneHeight);
                window.officeReferenceWidth = \(OfficeChrome.preferredPanelSize.width - 28);
                window.officeBaseScale = \(OfficeChrome.officeScale);
                window.officeMaximumVisibleFloors = \(OfficeChrome.maximumVisibleFloors);
                window.officeInitialZoom = \(officeZoom);
                window.officeInitialShowSkinDesks = \(showSkinDesks);
                window.officeInitialLanguage = '\(language.rawValue)';
                """,
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
        pushRobotSkin()
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
        usageVisibilityTask?.cancel()
        usageVisibilityTask = windowVisible ? Task { [weak self] in await self?.refreshUsage() } : nil
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
        requestLiveQuotaIfNeeded()
        #if OFFICE_UI_TEST
        let scope = offscreenUsageScope
        #else
        let scope: CodexTokenUsage.Scope = windowVisible ? .full : .menu
        #endif
        usageRefreshID += 1
        let refreshID = usageRefreshID
        let account = quotaLogAccount
        let result = (try? await usageCollector.snapshot(refreshPrices: windowVisible, quotaAccount: account, scope: scope))
            .flatMap(TokenUsageSnapshot.init(data:))
        guard !Task.isCancelled, refreshID == usageRefreshID, account == quotaLogAccount else { return }
        usage = result
        usageQuotaAccount = account
        usageLoaded = true
        usageIncludesDetails = scope == .full
        tokenMeter?.update(rate: result?.tokensPerMinute)
        refreshMenu()
        if usageIncludesDetails { pushUsage() }
    }

    private var quotaLogAccount: String? {
        liveQuotaEnabled ? liveQuota?.account : nil
    }

    private func pushUsage() {
        guard sceneReady, usageLoaded else { return }
        #if !OFFICE_UI_TEST
        guard windowVisible else { return }
        #endif
        var payload = usage.map { usagePayload($0.payload) }
        // The scene keeps its previous chart while a visible refresh fills in the details.
        if !usageIncludesDetails { payload?["history_status"] = "loading" }
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

    private func usagePayload(_ local: OfficeJSON) -> OfficeJSON {
        var payload = local
        if liveQuotaEnabled, let liveQuota {
            payload = liveQuota.displayPayload(local)
        } else if usageQuotaAccount != nil {
            payload["quota"] = NSNull()
            payload["quota_windows"] = [] as [OfficeJSON]
            payload["quota_closed_windows"] = [] as [OfficeJSON]
            payload["quota_plan"] = NSNull()
            payload["quota_sampled_at"] = NSNull()
            payload["quota_source"] = liveQuotaEnabled ? "loading" : "local_loading"
        }
        payload.removeValue(forKey: "quota_account")
        return payload
    }

    private func requestLiveQuotaIfNeeded() {
        #if OFFICE_UI_TEST
        let executable = offscreenQuotaExecutable
        let viewingUsage = showingUsage
        #else
        let viewingUsage = showingUsage && windowVisible
        #endif
        let uptime = ProcessInfo.processInfo.systemUptime
        guard liveQuotaEnabled, viewingUsage || menuBarMetric == .planRemaining,
              liveQuotaTask == nil, uptime >= nextLiveQuotaRead else { return }
        #if OFFICE_UI_TEST
        guard executable != nil else { return }
        #endif
        #if !OFFICE_UI_TEST
        let executable = Self.codexExecutable()
        #endif
        liveQuotaTask = Task { [weak self, codexHome] in
            let result = await OfficeLiveQuota.read(executable: executable, home: codexHome)
            guard let self, !Task.isCancelled else { return }
            self.liveQuotaTask = nil
            self.liveQuota = result
            let nextReset = result.windows?.compactMap(\.resets).filter { $0 > Date() }.min()
            let interval = nextReset.map { max(5, min(60, $0.timeIntervalSinceNow + 1)) } ?? 60
            self.nextLiveQuotaRead = ProcessInfo.processInfo.systemUptime + interval
            self.refreshMenu()
            self.pushUsage()
            if self.usageQuotaAccount != result.account { await self.refreshUsage() }
        }
        pushUsage()
    }

    private static func codexExecutable() -> URL? {
        let relative = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let desktop = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        var candidates = [desktop?.appendingPathComponent(relative),
                          URL(fileURLWithPath: "/Applications/ChatGPT.app").appendingPathComponent(relative),
                          URL(fileURLWithPath: "/Applications/Codex.app").appendingPathComponent(relative)].compactMap { $0 }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates += [home.appendingPathComponent(".local/bin/codex"),
                       URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func pushSnapshot(allowOffscreen: Bool = false) {
        guard sceneReady, windowVisible || allowOffscreen, let snapshot else { return }
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
            let usageView = body["view"] as? String == "usage"
            let floorCount = min(OfficeChrome.maximumVisibleFloors, max(0, body["floorCount"] as? Int ?? 0))
            let preferredSize: NSSize?
            if let width = body["officeWidth"] as? Int, (1...1600).contains(width),
               let height = body["officeHeight"] as? Int, (1...1600).contains(height) {
                preferredSize = NSSize(width: width + 28, height: height)
            } else {
                preferredSize = nil
            }
            let resizePanel = showingUsage != usageView || officeFloorCount != floorCount || officePreferredSize != preferredSize
            showingUsage = usageView
            officeFloorCount = floorCount
            officePreferredSize = preferredSize
            if resizePanel && windowVisible { positionWindow() }
            #if OFFICE_UI_TEST
            if resizePanel && offscreenPanelBounds != nil && !windowVisible { positionWindow() }
            #endif
            if !showingUsage { usageDayTask?.cancel() }
            else { requestLiveQuotaIfNeeded() }
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
        case "loadPipelineRepositories":
            if let request = body["request"] as? Int, request > 0 {
                requestPipelineRepositories(request: request)
            }
        case "rememberPipelineRepository":
            if let repository = body["repository"] as? String, pipelineRepositories[repository] != nil {
                rememberPipelinePreference(.repository(repository))
            } else if body["repository"] is NSNull {
                rememberPipelinePreference(.repository(nil))
            }
        case "rememberPipelineAuthentication":
            if let repository = body["repository"] as? String, pipelineRepositories[repository] != nil,
               let useCLI = body["useCLI"] as? Bool {
                rememberPipelinePreference(.authentication(repository: repository, useCLI: useCLI))
            }
        case "rememberPipelineVercelProject":
            if let repository = body["repository"] as? String, pipelineRepositories[repository] != nil {
                if body["project"] is NSNull {
                    rememberPipelinePreference(.vercelProject(repository: repository, project: nil))
                } else if let value = body["project"] as? OfficeJSON, let project = OfficePipelinePreferences.vercelProject(value) {
                    rememberPipelinePreference(.vercelProject(repository: repository, project: project))
                }
            }
        case "loadPipeline":
            if let request = body["request"] as? Int, request > 0 {
                let selection: PipelineSelection?
                if let repository = body["repository"] as? String {
                    selection = pipelineRepositories[repository] != nil ? .repository(repository) : nil
                } else {
                    selection = officeThreadID(body["id"]).map(PipelineSelection.workspace)
                }
                if let selection {
                    requestPipeline(selection, request: request, selectedRun: body["run"] as? Int,
                                    automatic: body["automatic"] as? Bool == true)
                } else {
                    pushPipeline(OfficePipelineSnapshot(), request: request)
                }
            }
        case "closePipeline":
            closePipeline()
        case "openPipelineLink":
            #if !OFFICE_UI_TEST
            if windowVisible, let result = pipelineResult, result.request == body["request"] as? Int,
               let source = body["source"] as? String, let index = body["index"] as? Int,
               let link = result.snapshot.link(source: source, index: index, releaseIndex: body["release"] as? Int) {
                NSWorkspace.shared.open(link)
            }
            #endif
        case "chooseProjectDirectory":
            if let request = body["request"] as? Int, request > 0 {
                chooseProjectDirectory(request: request, currentPath: body["path"] as? String)
            }
        case "loadAppSettings":
            pushAppSettings()
        case "chooseRobotSkin":
            chooseRobotSkin(folder: body["folder"] as? Bool == true)
        case "resetRobotSkin":
            resetRobotSkin()
        case "loadRobotSkinImage":
            if let index = body["index"] as? Int, body["revision"] as? Int == robotSkinRevision,
               robotSkinImages.indices.contains(index) {
                let image = robotSkinImages[index]
                let isGIF = OfficeRobotSkin.isGIF(image)
                let still = isGIF ? OfficeRobotSkin.stillFrame(image)?.base64EncodedString() : nil
                webView.callAsyncJavaScript("window.officeReceiveRobotSkinImage(image, index, revision, still);",
                    arguments: ["image": image.base64EncodedString(), "index": index, "revision": robotSkinRevision,
                                "still": still as Any? ?? NSNull()],
                    in: nil, in: .page, completionHandler: nil)
            }
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
                    self.officeZoom = office["office_zoom"] as? Int ?? 100
                    self.showSkinDesks = office["show_skin_desks"] as? Bool ?? true
                    let enabled = office["live_quota"] as? Bool ?? OfficeSettings.defaultLiveQuota
                    if enabled != self.liveQuotaEnabled {
                        self.liveQuotaEnabled = enabled
                        self.liveQuotaTask?.cancel()
                        self.liveQuotaTask = nil
                        self.liveQuota = nil
                        self.nextLiveQuotaRead = 0
                        self.pushUsage()
                        if !enabled && self.usageQuotaAccount != nil { await self.refreshUsage() }
                    }
                    self.requestLiveQuotaIfNeeded()
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

    private func requestPipelineRepositories(request: Int) {
        #if !OFFICE_UI_TEST
        guard windowVisible else { return }
        #endif
        pipelineRepositoriesTask?.cancel()
        pipelineRepositoriesTask = Task { [weak self] in
            guard let self else { return }
            let paths = await self.activityCollector.pipelineProjectPaths()
            let repositories = await OfficePipelineWorkspace.repositories(in: paths)
            guard !Task.isCancelled else { return }
            self.pipelineRepositoriesTask = nil
            self.pipelineRepositories = repositories
            self.webView.callAsyncJavaScript("window.officeReceivePipelineRepositories(repositories, preferences, request);",
                                            arguments: ["repositories": repositories.keys.sorted(), "preferences": self.pipelinePreferences.values,
                                                        "request": request], in: nil, in: .page,
                                            completionHandler: nil)
        }
    }

    private func rememberPipelinePreference(_ change: OfficePipelinePreferenceChange) {
        #if !OFFICE_UI_TEST
        guard windowVisible else { return }
        #endif
        let before = pipelinePreferences
        pipelinePreferences.apply(change)
        guard before != pipelinePreferences else { return }
        let previous = pipelinePreferenceWrite
        pipelinePreferenceWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.activityCollector.updatePipelinePreference(change)
            } catch {
                _ = try? await self.webView.evaluateJavaScript("window.officePipelinePreferenceSaveFailed()")
            }
        }
    }

    private func requestPipeline(_ selection: PipelineSelection, request: Int, selectedRun: Int?, automatic: Bool) {
        #if !OFFICE_UI_TEST
        guard windowVisible else { return }
        #endif
        guard pipelineTask == nil else { return }
        let useCLI: Bool
        switch selection {
        case .repository(let repository): useCLI = pipelinePreferences.ghRepositories.contains(repository)
        case .workspace: useCLI = false
        }
        let preferenceWrite = pipelinePreferenceWrite
        pipelineTask = Task { [weak self] in
            await preferenceWrite?.value
            guard let self, !Task.isCancelled else { return }
            let previous = self.pipelineResult.flatMap { $0.selection == selection && $0.useCLI == useCLI ? $0.snapshot : nil }
            let result: OfficePipelineSnapshot
            switch selection {
            case .repository(let repository):
                let workspaces = self.pipelineRepositories[repository] ?? []
                let project = self.pipelinePreferences.vercelProjects[repository]
                result = await self.pipeline.repositorySnapshot(repository: repository, workspaces: workspaces, vercelProject: project, useCLI: useCLI,
                                                                selectedRun: selectedRun, previous: previous, automatic: automatic)
            case .workspace(let thread):
                let threads = self.snapshot?.payload["threads"] as? [OfficeJSON] ?? []
                let hasProject = threads.contains { $0["id"] as? String == thread && $0["project_id"] is String }
                let workspace = hasProject ? await self.activityCollector.pipelineWorkspace(for: thread) : nil
                result = await self.pipeline.deploymentSnapshot(workspace: workspace,
                                                                 vercelProjects: self.pipelinePreferences.vercelProjects,
                                                                 previous: previous, automatic: automatic)
            }
            guard !Task.isCancelled else { return }
            self.pipelineTask = nil
            self.pipelineResult = (request, selection, useCLI, result)
            self.pushPipeline(result, request: request)
        }
    }

    private func pushPipeline(_ result: OfficePipelineSnapshot, request: Int) {
        guard let data = try? JSONEncoder().encode(result),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? OfficeJSON else { return }
        webView.callAsyncJavaScript("window.officeReceivePipeline(result, request);",
                                   arguments: ["result": payload, "request": request], in: nil, in: .page,
                                   completionHandler: nil)
    }

    private func closePipeline() {
        pipelineRepositoriesTask?.cancel()
        pipelineRepositoriesTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        pipelineResult = nil
    }

    private func chooseProjectDirectory(request: Int, currentPath: String?) {
        #if OFFICE_UI_TEST
        reportProjectDirectory(offscreenProjectDirectoryPicker?(currentPath), request: request)
        #else
        guard windowVisible, window.attachedSheet == nil, filePicker == nil else {
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
        filePicker = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.filePicker = nil
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

    private func chooseRobotSkin(folder: Bool) {
        guard !importingRobotSkin else { return }
        #if OFFICE_UI_TEST
        importRobotSkin(offscreenRobotSkinPicker?(folder) ?? [], folder: folder)
        #else
        guard windowVisible, window.attachedSheet == nil, filePicker == nil else {
            pushRobotSkin()
            return
        }
        let panel = NSOpenPanel()
        panel.title = folder
            ? language.text("选择机器人皮肤文件夹", "Choose a robot skin folder")
            : language.text("选择机器人皮肤图片", "Choose robot skin images")
        panel.prompt = language.text("选择", "Choose")
        if !folder { panel.allowedContentTypes = [.image] }
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = !folder
        filePicker = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.filePicker = nil
            self.importRobotSkin(response == .OK ? panel?.urls ?? [] : [], folder: folder)
        }
        #endif
    }

    private func importRobotSkin(_ urls: [URL], folder: Bool) {
        guard !urls.isEmpty else {
            pushRobotSkin()
            return
        }
        importingRobotSkin = true
        pushRobotSkin("importing")
        let storage = robotSkin
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let group = try OfficeRobotSkin.prepare(urls, folder: folder)
                    try storage.save(group.images)
                    return group
                }
            }.value
            guard let self else { return }
            self.importingRobotSkin = false
            switch result {
            case .success(let group):
                self.robotSkinImages = group.images
                self.robotSkinRevision += 1
                self.pushRobotSkin(group.skipped == 0 ? "saved" : "partial", skipped: group.skipped)
            case .failure(OfficeRobotSkin.ImportError.invalidImage):
                self.pushRobotSkin("invalid")
            case .failure(OfficeRobotSkin.ImportError.tooManyImages):
                self.pushRobotSkin("tooMany")
            case .failure:
                self.pushRobotSkin("storage")
            }
        }
    }

    private func resetRobotSkin() {
        #if !OFFICE_UI_TEST
        guard windowVisible else { return }
        #endif
        guard !importingRobotSkin, filePicker == nil else {
            pushRobotSkin()
            return
        }
        do {
            try robotSkin.remove()
            robotSkinImages = []
            robotSkinRevision += 1
            pushRobotSkin("reset")
        } catch {
            pushRobotSkin("storage")
        }
    }

    private func pushRobotSkin(_ status: String = "", skipped: Int = 0) {
        guard sceneReady else { return }
        webView.callAsyncJavaScript("window.officeReceiveRobotSkin(count, revision, status, busy, skipped);",
            arguments: ["count": robotSkinImages.count, "revision": robotSkinRevision, "status": status,
                        "busy": importingRobotSkin, "skipped": skipped],
            in: nil, in: .page, completionHandler: nil)
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

    func refreshOffscreenUsage() async {
        await refreshUsage()
    }

    func pushOffscreenUsage() {
        pushUsage()
    }

    func refreshOffscreenActivity() async {
        await refreshActivity()
        pushSnapshot(allowOffscreen: true)
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
        closePipeline()
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
