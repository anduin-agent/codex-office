import AppKit
import SQLite3
import WebKit

@main
enum OfficeUITest {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail("Expected the resource directory and temporary workspace")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard app.activationPolicy() == .prohibited, !app.isActive else {
            fail("Unable to prohibit activation of the offscreen test")
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let workspace = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let home = workspace.appendingPathComponent("codex")
        let settings = workspace.appendingPathComponent("office.json")
        do {
            let sessions = home.appendingPathComponent("sessions")
            let projects = workspace.appendingPathComponent("usage-projects")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let calendar = Calendar.current
            let firstDay = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date()))!
            let timestamp = ISO8601DateFormatter().string(from: firstDay.addingTimeInterval(3600))
            var titles = ""
            for (index, count) in [40, 60].enumerated() {
                let id = "00000000-0000-0000-0000-00000000000\(index + 1)"
                let project = projects.appendingPathComponent("project-\(index + 1)")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
                                                        withIntermediateDirectories: true)
                let metadata = try JSONSerialization.data(withJSONObject: ["id": id, "cwd": project.path])
                let model = index == 1 ? "gpt-5-mini" : "test-model-1"
                let log = """
                {"timestamp":"\(timestamp)","type":"session_meta","payload":\(String(decoding: metadata, as: UTF8.self))}
                {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)"}}
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(count)},"last_token_usage":{"total_tokens":\(count),"input_tokens":\(count - 20),"output_tokens":20,"cached_input_tokens":0}}}}

                """
                try log.write(to: sessions.appendingPathComponent("usage-\(index).jsonl"), atomically: true, encoding: .utf8)
                titles += "{\"id\":\"\(id)\",\"thread_name\":\"Usage chat \(index + 1)\"}\n"
            }
            let owner = "00000000-0000-0000-0000-000000000002"
            for (index, kind, parent, count, title) in [
                (3, "subagent", owner, 15, "Worker"),
                (4, "guardian_review", owner, 10, "Linked review"),
                (5, "guardian_review", "", 5, "Unlinked review"),
            ] {
                let id = "00000000-0000-0000-0000-00000000000\(index)"
                var fields = ["id": id, "thread_source": kind, "model": "background-model"]
                if !parent.isEmpty { fields["parent_thread_id"] = parent }
                let metadata = try JSONSerialization.data(withJSONObject: fields)
                let log = """
                {"timestamp":"\(timestamp)","type":"session_meta","payload":\(String(decoding: metadata, as: UTF8.self))}
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(count)},"last_token_usage":{"total_tokens":\(count)}}}}

                """
                try log.write(to: sessions.appendingPathComponent("usage-\(index).jsonl"), atomically: true, encoding: .utf8)
                titles += "{\"id\":\"\(id)\",\"thread_name\":\"\(title)\"}\n"
            }
            try titles.write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
            try writeProjectDirectories(to: home, workspace: workspace)
        } catch {
            fail("Unable to create the temporary Codex fixture: \(error)")
        }
        let office = OfficeApplication(
            sceneURL: resources.appendingPathComponent("office.html"),
            codexHome: home.path, configFile: settings.path
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            fail("Offscreen settings verification timed out")
        }
        Task { @MainActor in
            let (panel, view) = office.loadOffscreenPanel()
            do {
                try await office.primeOffscreenUsage()
                try checkMaterials(panel, view)
                try checkToolbarLayout()
                try checkReleaseVersions()
                try await checkToolbar(panel, view)
                try await checkAgentTeam(panel, view)
                try await checkProjectAliases(office, panel, view, workspace: workspace, settings: settings)
                try await checkSettings(office, panel, view, settings)
                try await checkDetailedUsage(office, panel, view)
                office.stopOffscreenPanel()
                print("Offscreen AppKit glass, toolbar, usage details, and WebKit settings checks passed")
                exit(EXIT_SUCCESS)
            } catch {
                office.stopOffscreenPanel()
                fail(String(describing: error))
            }
        }
        app.run()
    }

    private static func writeProjectDirectories(to home: URL, workspace: URL) throws {
        var database: OpaquePointer?
        let path = home.appendingPathComponent("state_5.sqlite").path
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw Failure("Could not create project database") }
        defer { sqlite3_close(database) }
        let root = workspace.standardizedFileURL.path.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE projects(id TEXT, name TEXT, position INTEGER);
            CREATE TABLE project_roots(project_id TEXT, path TEXT, position INTEGER);
            INSERT INTO projects VALUES ('one','Managed project',1), ('two','Second project',2);
            INSERT INTO project_roots VALUES ('one','\(root)/managed',0), ('one','\(root)/./managed',1),
                ('two','\(root)/second',0), ('two','invalid-relative-path',1);
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure("Could not populate project database")
        }
        let legacy = workspace.appendingPathComponent("legacy-codex")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let state = try JSONSerialization.data(withJSONObject: [
            "local-projects": ["legacy": ["name": "Legacy project", "rootPaths": [workspace.path + "/legacy"]]],
        ])
        try state.write(to: legacy.appendingPathComponent(".codex-global-state.json"))
        guard readOfficeProjectDirectories(legacy) == [["name": "Legacy project", "path": officeCanonicalPath(workspace.path)! + "/legacy"]] else {
            throw Failure("The legacy project catalog was not recognized")
        }
    }

    @MainActor
    private static func checkProjectAliases(_ office: OfficeApplication, _ panel: NSPanel, _ view: WKWebView,
                                            workspace: URL, settings: URL) async throws {
        let manual = workspace.appendingPathComponent("manual folder", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        guard let managedPath = officeCanonicalPath(workspace.path + "/managed"),
              let manualPath = officeCanonicalPath(manual.path) else { throw Failure("Invalid test folder path") }
        try button(.settings, in: panel).performClick(nil)
        try await expect("Settings are ready for project aliases", panel, view,
                         "document.querySelector('#office-settings').open && !document.querySelector('#office-settings fieldset').disabled")
        _ = try await view.evaluateJavaScript("document.querySelector('#add-alias').click()")
        try await expect("The directory selector lists unique registered Codex projects", panel, view, """
            (() => {
                const select = document.querySelector('.alias-directory');
                const options = [...select.options].slice(1);
                return select.hidden && options.length===2 && options[0].label.startsWith('Managed project · ') &&
                    options[1].label.startsWith('Second project · ') &&
                    document.querySelectorAll('.alias-row input').length===1;
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const row = document.querySelector('.alias-row');
                const combo = row.querySelector('[role=combobox]');
                for (const key of ['ArrowDown','Enter']) {
                    combo.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
                }
                const input = row.querySelector('input');
                input.value = 'My alias';
                input.dispatchEvent(new Event('change',{bubbles:true}));
            })()
            """)
        try await expect("Choosing a Codex directory saves the alias", panel, view,
                         "document.querySelector('#settings-feedback').textContent==='已保存'")
        var saved = try OfficeSettings(url: settings).load()["projects"] as? [String: String]
        guard saved == [managedPath: "My alias"] else { throw Failure("The selected Codex project was not saved") }

        var requestedPath: String?
        office.offscreenProjectDirectoryPicker = { path in
            requestedPath = path
            return manual
        }
        _ = try await view.evaluateJavaScript("document.querySelector('.alias-browse').click()")
        try await expect("A folder chosen through the bridge replaces the selected directory", panel, view,
                         "document.querySelector('.alias-directory').value.endsWith('/manual folder') && document.querySelector('#settings-feedback').textContent==='已保存'")
        saved = try OfficeSettings(url: settings).load()["projects"] as? [String: String]
        guard requestedPath == managedPath, saved == [manualPath: "My alias"] else {
            throw Failure("The browse action did not pass the current folder and save the replacement")
        }
        office.offscreenProjectDirectoryPicker = { path in
            requestedPath = path
            return nil
        }
        _ = try await view.evaluateJavaScript("document.querySelector('.alias-browse').click()")
        for _ in 0..<80 {
            if requestedPath == manualPath { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard requestedPath == manualPath else { throw Failure("The cancellation fixture did not run") }
        try await expect("Cancelling the picker preserves the current directory", panel, view,
                         "document.querySelector('.alias-directory').value.endsWith('/manual folder')")
        _ = try await view.evaluateJavaScript("""
            document.querySelector('.alias-remove').click();
            document.querySelector('#close-settings').click();
            """)
        try await expect("Removing the alias disposes its dropdown and saves the removal", panel, view, """
            document.querySelector('#settings-feedback').textContent==='已保存' &&
            !document.querySelector('.alias-row') &&
            ![...document.querySelectorAll('.office-dropdown-list')].some(list => list.getAttribute('aria-label')==='项目目录')
            """)
        saved = try OfficeSettings(url: settings).load()["projects"] as? [String: String]
        guard saved?.isEmpty == true else { throw Failure("The removed alias remained in settings") }
        office.offscreenProjectDirectoryPicker = nil
    }

    @MainActor
    private static func checkReleaseVersions() throws {
        let stable = Data(#"{"tag_name":"v0.10.0","draft":false,"prerelease":false}"#.utf8)
        let prerelease = Data(#"{"tag_name":"v1.0.0-rc.1","draft":false,"prerelease":true}"#.utf8)
        let available = OfficeReleaseCheck.compare(currentVersion: "0.9.0", releaseData: stable)
        guard available.0 == .available, available.1 == "0.10.0",
              OfficeReleaseCheck.compare(currentVersion: "0.10.0", releaseData: stable).0 == .current,
              OfficeReleaseCheck.compare(currentVersion: "0.9.0", releaseData: prerelease).0 == .failed,
              OfficeReleaseCheck(repository: "owner/repo")?.releasesPage.host == "github.com",
              OfficeReleaseCheck(repository: "https://github.com/owner/repo") == nil else {
            throw Failure("Release checks must use numeric versions and the configured GitHub repository")
        }
    }

    @MainActor
    private static func checkMaterials(_ panel: NSPanel, _ view: WKWebView) throws {
        guard let chrome = panel.contentView?.subviews.compactMap({ $0 as? OfficeChrome }).first else {
            throw Failure("Native panel chrome is missing")
        }
        if #available(macOS 26.0, *) {
            guard let glass = chrome.materialView as? NSGlassEffectView, glass.style == .clear else {
                throw Failure("The panel should use clear Liquid Glass")
            }
        } else if !(chrome.materialView is NSVisualEffectView) {
            throw Failure("Native frost view is missing")
        }
        let fallback = OfficeChrome(scene: NSView(), target: panel,
                                    action: #selector(NSWindow.performClose(_:)), preferLiquidGlass: false)
        guard let frost = fallback.materialView as? NSVisualEffectView,
              frost.blendingMode == .behindWindow, frost.material == .popover else {
            throw Failure("The older macOS fallback must blur behind the window")
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let scene = chrome.convert(view.bounds, from: view)
        guard chrome.bounds.width == OfficeChrome.preferredPanelSize.width,
              chrome.bounds.height == 620,
              scene.width > 0, scene.height > 0, scene.minX >= 12, scene.minY >= 12,
              chrome.bounds.maxX - scene.maxX >= 12, abs(chrome.bounds.maxY - scene.maxY - 46) < 0.5 else {
            throw Failure("The scene must leave a visible glass frame and toolbar around it: panel \(panel.frame), chrome \(chrome.bounds), scene \(scene)")
        }
    }

    @MainActor
    private static func checkToolbarLayout() throws {
        let size = OfficeChrome.preferredPanelSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for liquidGlass in [true, false] {
            let chrome = OfficeChrome(scene: NSView(), target: panel,
                                      action: #selector(NSWindow.performClose(_:)), preferLiquidGlass: liquidGlass)
            // Size the chrome directly so AppKit's offscreen NSPanel frame negotiation
            // does not substitute a content fitting width for the width under test.
            panel.contentView?.addSubview(chrome)
            chrome.setReady(true)
            let settings = try button(.settings, in: chrome)
            let actions = try [button(.waiting, in: chrome), button(.collaboration, in: chrome), settings]
            guard let toolbar = settings.superview else { throw Failure("Missing toolbar") }
            let labels = toolbar.subviews.compactMap { $0 as? NSTextField }
            for language in [OfficeLanguage.simplifiedChinese, .english, .simplifiedChinese] {
                chrome.setLanguage(language)
                for waitingCount in [256, 0, 1] {
                    chrome.update([
                        "source": language.text("本机数据暂时不可用 · 部分数据", "Local activity is temporarily unavailable · Partial data"),
                        "sourceStatus": "partial",
                        "runningCount": 123,
                        "waitingCount": waitingCount,
                        "collaborationTitle": language.text("跨项目协作 999/999", "Cross-project collaboration 999/999"),
                    ])
                    for width in [size.width, 560, 420, 240] {
                        chrome.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
                        chrome.layoutSubtreeIfNeeded()
                        let visible = actions.filter { !$0.isHiddenOrHasHiddenAncestor }
                        let context = "\(language.rawValue), \(width) pt, waiting=\(waitingCount), glass=\(liquidGlass)"
                        guard let title = labels.first(where: { $0.stringValue == "Codex Office" }),
                              !title.isHidden, title.lineBreakMode == .byClipping,
                              title.frame.width >= title.intrinsicContentSize.width + 8,
                              labels.first(where: { $0 !== title })?.textColor == .systemBlue,
                              chrome.bounds.width == width, toolbar.bounds.width == width,
                              visible.count == (waitingCount > 0 ? 3 : 2),
                              settings.image != nil, settings.imagePosition == .imageOnly,
                              settings.frame.width == 45
                        else { throw Failure("Toolbar actions or settings icon changed: \(context), bounds \(chrome.bounds), settings \(settings.frame)") }
                        var previousEdge = title.frame.maxX
                        for action in visible {
                            let rect = action.frame
                            let point = toolbar.convert(NSPoint(x: rect.midX, y: rect.midY), to: toolbar.superview)
                            guard toolbar.bounds.contains(rect), rect.height == 32, rect.width >= (width == 240 ? 20 : 45),
                                  rect.minX >= previousEdge + 1, toolbar.hitTest(point) === action
                            else { throw Failure("Overlapping, clipped, or inaccessible toolbar action \(action.identifier?.rawValue ?? ""): \(context)") }
                            previousEdge = rect.maxX
                        }
                    }
                }
            }
            chrome.removeFromSuperview()
        }
        guard !panel.isVisible, !panel.isKeyWindow, !NSApp.isActive else {
            throw Failure("Toolbar layout verification must stay offscreen")
        }
    }

    @MainActor
    private static func checkToolbar(_ panel: NSPanel, _ view: WKWebView) async throws {
        try await expect("Native mode hides the HTML toolbar", panel, view, """
            document.documentElement.classList.contains('native-toolbar') &&
            getComputedStyle(document.querySelector('header')).display === 'none' &&
            typeof window.officeLocateWaiting === 'function'
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const now = new Date().toISOString();
                window.officeSetSnapshot({source_status:'ok',collected_at:now,projects:[],threads:[
                    {id:'running',root_id:'running',status:'running',title:'测试运行',last_activity:now},
                    {id:'waiting',root_id:'waiting',status:'waiting',title:'测试待确认',last_activity:'2026-01-01T00:00:00Z'}
                ]}, null, {});
                window.officeSetUsage({live_status:'ok',tokens_per_minute:12500,
                    today_status:'ok',today_tokens:342500,today_estimated_usd:1.23,today_priced_tokens:300000,history_status:'loading'});
            })()
            """)
        let waiting = try button(.waiting, in: panel)
        let collaboration = try button(.collaboration, in: panel)
        for _ in 0..<80 {
            if !waiting.isHidden, waiting.title == "1 个待确认" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !waiting.isHidden, waiting.title == "1 个待确认" else {
            throw Failure("Scene state did not reach the native toolbar")
        }
        try await expect("The usage summary and rounded tabs occupy separate rows while history loads", panel, view, """
            (() => {
                const today = document.querySelector('#office-tokens-today');
                const rate = document.querySelector('#office-token-rate');
                const cost = document.querySelector('#office-cost-today');
                const metrics = document.querySelector('.office-usage-summary');
                const summary = metrics.getBoundingClientRect();
                const tabs = document.querySelector('.view-tabs').getBoundingClientRect();
                const stage = document.querySelector('.stage').getBoundingClientRect();
                const tab = document.querySelector('#show-office');
                return today.title==='342,500' && rate.title==='12,500' &&
                    today.textContent==='342.5K tokens' && rate.textContent==='12.5K/min' &&
                    cost.textContent.includes('$1.23') && cost.title.includes('仅部分用量可估价') &&
                    !metrics.textContent.includes('部分估算') && summary.height>=60 &&
                    [...metrics.children].slice(1).every(metric => getComputedStyle(metric).borderLeftWidth==='1px') &&
                    parseFloat(getComputedStyle(today).fontSize)>=15 &&
                    parseFloat(getComputedStyle(tab).borderTopLeftRadius)>=15 &&
                    summary.height>0 && tabs.height>0 && summary.bottom<=tabs.top && tabs.bottom<=stage.top;
            })()
            """)
        let settings = try button(.settings, in: panel)
        let runningLabel = settings.superview?.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "1 个聊天运行中" }
        guard runningLabel?.textColor == .systemBlue else {
            throw Failure("The real scene's running count did not get the toolbar highlight color")
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard [waiting, collaboration, settings].allSatisfy({ $0.frame.height == 32 }) else {
            throw Failure("Toolbar buttons must retain their 32-point height")
        }
        if let content = panel.contentView {
            for action in [waiting, collaboration, settings] {
                let center = action.convert(NSPoint(x: action.bounds.midX, y: action.bounds.midY), to: content.superview)
                guard content.hitTest(center) === action else {
                    throw Failure("The panel does not deliver clicks to \(action.identifier?.rawValue ?? "toolbar action")")
                }
            }
        }
        waiting.performClick(nil)
        try await expect("Native button locates the waiting chat", panel, view,
                         "document.querySelector('#detail strong').textContent === '测试待确认'")
        _ = try await view.evaluateJavaScript("document.querySelector('#show-usage').click()")
        try await expect("The Usage tab switches the main panel", panel, view, """
            !document.querySelector('#usage-panel').hidden && document.querySelector('#office-view').hidden &&
            document.querySelector('#show-usage').getAttribute('aria-pressed')==='true' &&
            !document.querySelector('dialog[open]')
            """)
        try await expect("Today's total and rate stay visible above the Usage tab while history loads", panel, view, """
            (() => {
                const today = document.querySelector('#office-tokens-today');
                const rate = document.querySelector('#office-token-rate');
                const tabs = document.querySelector('.view-tabs').getBoundingClientRect();
                return document.querySelector('#usage-history').hidden &&
                    !document.querySelector('#usage-history-placeholder').hidden &&
                    document.querySelector('#usage-history-status').textContent==='正在读取本机历史…' &&
                    today.title==='342,500' && rate.title==='12,500' &&
                    today.getBoundingClientRect().width>0 && rate.getBoundingClientRect().width>0 &&
                    tabs.bottom<=document.querySelector('#usage-panel').getBoundingClientRect().top;
            })()
            """)
        try await checkUsageDisplay(panel, view)
        _ = try await view.evaluateJavaScript("document.querySelector('#show-office').click()")
        try await expect("The Office tab returns to the office", panel, view, """
            document.querySelector('#usage-panel').hidden && !document.querySelector('#office-view').hidden &&
            document.querySelector('#show-office').getAttribute('aria-pressed')==='true'
            """)
        _ = try await view.evaluateJavaScript("window.officeOpenUsage()")
        try await expect("The menu action still opens Usage", panel, view, "!document.querySelector('#usage-panel').hidden")
        collaboration.performClick(nil)
        try await expect("Collaboration help stays hidden until the title question mark is hovered", panel, view, """
            (() => {
                const modal = document.querySelector('#collaboration-panel');
                const tooltip = document.querySelector('#collaboration-help-tooltip');
                const button = modal.querySelector('.dialog-title .setting-help');
                if (!modal.open || !tooltip.hidden || !document.querySelector('#collaboration-help').hidden) return false;
                const height = modal.getBoundingClientRect().height;
                button.dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'}));
                const shown = !tooltip.hidden && tooltip.textContent.includes('自动识别') &&
                    tooltip.textContent.includes('本机 Codex 日志') && tooltip.textContent.includes('手动记录派发') &&
                    tooltip.textContent.includes('不会发送消息或启动任务') && height===modal.getBoundingClientRect().height;
                button.dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse'}));
                return shown && tooltip.hidden && document.querySelector('#usage-panel').hidden;
            })()
            """)
    }

    @MainActor
    private static func checkUsageDisplay(_ panel: NSPanel, _ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("""
            const days = Array.from({length:30},(_,i)=>{
                const date = new Date();
                date.setDate(date.getDate()-29+i);
                const day = [date.getFullYear(),date.getMonth()+1,date.getDate()]
                    .map((part,index)=>String(part).padStart(index?2:4,'0')).join('-');
                return {day,tokens:i===0?130:i===29?40:0,
                    ...(i===0?{input_tokens:100,output_tokens:30,breakdown_tokens:130,
                        estimated_input_usd:0.75,priced_input_tokens:100,estimated_output_usd:0.50,priced_output_tokens:30,
                        estimated_cached_input_usd:0.05,priced_cached_input_tokens:25,
                        cached_input_tokens:25,cache_reported_input_tokens:100}:{}),
                    ...(i===29?{input_tokens:20,output_tokens:10,breakdown_tokens:30,
                        cached_input_tokens:10,cache_reported_input_tokens:10}:{}),
                    estimated_usd:i===0?1.25:i===29?0.125:0,priced_tokens:i===0?130:i===29?20:0};
            });
            window.usageHistoryFixture = {
                live_status:'ok',tokens_per_minute:12500,live_estimated_usd:0.25,live_priced_tokens:10000,history_status:'ok',
                history:{first_day:'2025-01-02',active_days:3,total_tokens:340,total_estimated_usd:2.50,
                    total_priced_tokens:260,prices_updated_at:days[29].day,days},
                quota:{window_minutes:10080,remaining_percent:42.5,
                    resets_at:new Date(Date.now()+((2*24+4)*60+17)*60000-15000).toISOString()}
            };
            window.officeSetUsage(window.usageHistoryFixture);
            """)
        try await expect("The chart fits the panel and hovering previews cost without changing the day", panel, view, """
            (() => {
                const bars = document.querySelector('#usage-bars');
                const first = bars.firstElementChild, last = bars.lastElementChild;
                const tip = document.querySelector('#usage-tooltip');
                first.dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'}));
                const correct = !tip.hidden && tip.textContent.includes(days[0].day) &&
                    tip.textContent.includes('130 tokens') && tip.textContent.includes('$1.25') &&
                    tip.textContent.includes('输入 100 · 输出 30') && tip.textContent.includes('缓存命中率 25%') &&
                    last.getAttribute('aria-pressed')==='true';
                first.dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse'}));
                last.dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'}));
                const partial = tip.textContent.includes('仅部分用量可估价');
                last.dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse'}));
                return bars.children.length===30 && first.getBoundingClientRect().width>8 &&
                    last.getBoundingClientRect().right<=document.documentElement.clientWidth &&
                    correct && partial && tip.hidden;
            })()
            """)
        try await expect("Usage shows the 30-day peak and qualifies partially reported daily metrics", panel, view, """
            document.querySelector('#usage-peak-date').textContent.length>0 &&
            document.querySelector('#usage-peak').textContent==='130 tokens' &&
            document.querySelector('#usage-peak-cost').textContent.includes('$1.25') &&
            document.querySelector('#usage-total').textContent==='340' &&
            document.querySelector('#usage-total-cost').textContent.includes('$2.50') &&
            document.querySelector('#usage-total-cost').title.includes('仅部分用量可估价') &&
            document.querySelector('#usage-price-note').textContent.includes('不代表实际扣费') &&
            document.querySelector('#usage-rate-cost').textContent.includes('$0.25') &&
            !document.querySelector('#office-token-rate-cost').hidden &&
            document.querySelector('#usage-day-input').textContent==='20' &&
            document.querySelector('#usage-day-output').textContent==='10' &&
            document.querySelector('#usage-day-cache').textContent==='100%' &&
            document.querySelector('#usage-day-cache').parentElement.title.includes('记录了缓存数据的输入')
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#usage-bars button').click()")
        try await expect("Clicking a date ranks local chats by that day's usage", panel, view, """
            (() => {
                const rows = [...document.querySelectorAll('#usage-ranking > li')];
                return document.querySelector('#usage-ranking-title').textContent.startsWith(days[0].day) &&
                    document.querySelector('#usage-day-input').textContent==='100' &&
                    document.querySelector('#usage-day-output').textContent==='30' &&
                    document.querySelector('#usage-day-cache').textContent==='25%' &&
                    document.querySelector('#usage-day-cache-count').textContent==='25 / 100 输入 Token' &&
                    document.querySelector('#usage-day-cost').textContent.includes('$1.25') &&
                    document.querySelector('#usage-day-input-cost').textContent.includes('$0.75') &&
                    document.querySelector('#usage-day-output-cost').textContent.includes('$0.50') &&
                    document.querySelector('#usage-day-cache-cost').textContent.includes('$0.05') &&
                    document.querySelector('#usage-day-cache').parentElement.title==='' &&
                    rows.length===3 && rows[0].querySelector('summary').textContent.includes('85 tokens') &&
                    rows[0].textContent.includes('Usage chat 2') && rows[0].textContent.includes('60 tokens') &&
                    rows[0].querySelector('summary small').textContent.includes('$0.0001') &&
                    rows[0].textContent.includes('Worker') && rows[0].textContent.includes('Linked review') &&
                    rows[1].textContent.includes('40 tokens') && rows[2].textContent.includes('未归属的自动审批') &&
                    rows[2].querySelector('summary').textContent.includes('5 tokens') &&
                    [...document.querySelectorAll('#usage-ranking details')].every(group => group.open);
            })()
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#usage-ranking-toggle').click()")
        try await expect("One click collapses every group", panel, view, """
            !document.querySelector('#usage-ranking details[open]') &&
            document.querySelector('#usage-ranking-toggle').textContent==='全部展开'
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#usage-ranking summary').click()")
        try await expect("A single group can expand independently", panel, view, """
            document.querySelectorAll('#usage-ranking details[open]').length===1 &&
            document.querySelector('#usage-ranking details').open &&
            document.querySelector('#usage-ranking-toggle').textContent==='全部收起'
            """)
        _ = try await view.evaluateJavaScript("""
            document.querySelector('#usage-ranking summary').click();
            """)
        try await expect("The same group can collapse independently", panel, view, """
            !document.querySelector('#usage-ranking details[open]') &&
            document.querySelector('#usage-ranking-toggle').textContent==='全部展开'
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#usage-ranking-toggle').click()")
        try await expect("One click restores every daily group", panel, view, """
            document.querySelectorAll('#usage-ranking details[open]').length===2
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetUsage({...window.usageHistoryFixture,history_status:'loading',history:null});
            document.querySelector('#show-office').click();
            document.querySelector('#show-usage').click();
            """)
        try await expect("A new indexing pass keeps the existing chart visible and marks the ranking as pending", panel, view, """
            !document.querySelector('#usage-history').hidden && document.querySelector('#usage-history-placeholder').hidden &&
            document.querySelector('#usage-history-status').textContent==='正在更新本机历史，显示上次统计。' &&
            document.querySelector('#usage-bars button').getAttribute('aria-pressed')==='true' &&
            document.querySelector('#usage-ranking-status').textContent==='历史更新完成后将显示当日会话用量。'
            """)
        _ = try await view.evaluateJavaScript("window.officeSetUsage(window.usageHistoryFixture)")
        try await expect("The completed index refreshes the ranking and clears the progress message", panel, view, """
            !document.querySelector('#usage-history').hidden && document.querySelector('#usage-history-status').hidden &&
            document.querySelectorAll('#usage-ranking > li').length===3
            """)
        try await expect("Today shows one measured bar and the weekly track shows remaining quota", panel, view, """
            (() => {
                const today = document.querySelector('#usage-bars button:last-child');
                const track = document.querySelector('#usage-plan-progress');
                return Math.abs(parseFloat(today?.style.getPropertyValue('--bar-height'))-40/130*100)<0.01 &&
                    getComputedStyle(today).backgroundColor==='rgba(0, 0, 0, 0)' &&
                    !track.hidden && track.value===42.5 && track.max===100 &&
                    document.querySelector('#usage-plan-label').textContent==='周额度剩余' &&
                    document.querySelector('#usage-plan-percent').textContent==='42.5%' &&
                    document.querySelector('#usage-plan-note').textContent.endsWith('重置') &&
                    document.querySelector('#usage-plan-countdown').textContent==='重置倒计时 2 天 4 小时 17 分钟';
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetVisible(true);
            window.officeSetUsage({quota:{window_minutes:10080,remaining_percent:0,
                resets_at:new Date(Date.now()+61500).toISOString()}});
            """)
        try await expect("Zero remaining quota still shows its empty track", panel, view, """
            !document.querySelector('#usage-plan-progress').hidden &&
            document.querySelector('#usage-plan-progress').value===0 &&
            document.querySelector('#usage-plan-percent').textContent==='0%'
            """)
        try await expect("Countdown advances without a new usage snapshot", panel, view, """
            document.querySelector('#usage-plan-countdown').textContent==='重置倒计时 1 分钟'
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetUsage({quota_windows:[
                {window_minutes:300,remaining_percent:73,resets_at:new Date(Date.now()+2500).toISOString(),
                    cycle_started_at:new Date(Date.now()-17997500).toISOString(),cycle_status:'ok',
                    cycle_tokens:2700000,cycle_estimated_tokens:10000000,previous_cycle:{
                        resets_at:new Date(Date.now()-17997500).toISOString(),sampled_at:new Date(Date.now()-18057500).toISOString(),
                        cycle_status:'ok',cycle_tokens:3400000,used_percent:68,cycle_estimated_tokens:5000000,
                        basis_sampled_at:new Date(Date.now()-18057500).toISOString(),basis_used_percent:68,basis_tokens:3400000
                    },cycle_comparison:{status:'higher',change_percent:100,tolerance_percent:15}},
                {window_minutes:10080,remaining_percent:34,resets_at:new Date(Date.now()+150000).toISOString(),
                    cycle_started_at:new Date(Date.now()-604650000).toISOString(),cycle_status:'partial',cycle_tokens:33000000}
            ]});
            """)
        try await expect("Five-hour and weekly quota show in order with separate progress and resets", panel, view, """
            (() => {
                const [short,weekly] = document.querySelectorAll('.usage-plan');
                return !short.hidden && !weekly.hidden && short.getBoundingClientRect().bottom<=weekly.getBoundingClientRect().top &&
                    short.querySelector('.usage-plan-label').textContent==='5 小时额度剩余' &&
                    weekly.querySelector('.usage-plan-label').textContent==='周额度剩余' &&
                    short.querySelector('progress').value===73 && weekly.querySelector('progress').value===34 &&
                    short.querySelector('.usage-plan-cycle').textContent.includes('2,700,000 tokens') &&
                    short.querySelector('.usage-plan-cycle').textContent.includes('≈ 10M tokens') &&
                    short.querySelector('.usage-plan-previous').textContent.includes('≈ 5M tokens') &&
                    short.querySelector('.usage-plan-previous strong').title.includes('3,400,000 tokens ÷ 68%') &&
                    short.querySelector('.usage-cycle-comparison').textContent==='可能增加 · 估算差 +100%' &&
                    document.querySelector('#usage-comparison-note').textContent.includes('±15%') &&
                    weekly.querySelector('.usage-plan-cycle').textContent.includes('本周期已记录 33,000,000 tokens') &&
                    !weekly.querySelector('.usage-plan-cycle').textContent.includes('估算容量') &&
                    !document.querySelector('#usage-cycle-note').hidden &&
                    short.querySelector('.usage-plan-countdown').textContent==='重置倒计时 1 分钟' &&
                    weekly.querySelector('.usage-plan-countdown').textContent==='重置倒计时 3 分钟';
            })()
            """)
        try await expect("The five-hour bar expires independently", panel, view, """
            document.querySelector('#usage-plan-label').textContent==='周额度剩余' &&
            document.querySelector('#usage-plan-progress').value===34 && document.querySelector('#usage-plan-second-label').parentElement.hidden &&
            document.querySelector('#usage-cycle-note').hidden
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetVisible(false);
            window.officeSetUsage({quota:{window_minutes:10080,remaining_percent:50,
                resets_at:new Date(Date.now()-60000).toISOString()}});
            """)
        try await expect("An expired quota hides its track", panel, view, """
            document.querySelector('#usage-plan-progress').hidden &&
            document.querySelector('#usage-plan-countdown').hidden &&
            document.querySelector('#usage-plan-percent').textContent==='—'
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetUsage({quota_windows:[],quota_closed_windows:[{window_minutes:10080,previous_cycle:{
                resets_at:new Date(Date.now()-60000).toISOString(),sampled_at:new Date(Date.now()-120000).toISOString(),
                cycle_status:'ok',cycle_tokens:3400000,used_percent:68,cycle_estimated_tokens:5000000
            }}]});
            """)
        try await expect("A closed weekly baseline stays visible while waiting for a new sample", panel, view, """
            document.querySelector('#usage-plan-progress').hidden &&
            document.querySelector('#usage-plan-note').textContent==='等待新周期额度记录' &&
            !document.querySelector('.usage-plan-previous').hidden &&
            document.querySelector('.usage-plan-previous').textContent.includes('≈ 5M tokens') &&
            document.querySelector('#usage-comparison-note').hidden
            """)
    }

    @MainActor
    private static func checkAgentTeam(_ panel: NSPanel, _ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("""
            document.querySelector('#collaboration-panel').close();
            (() => {
                const now = new Date().toISOString();
                const root = {id:'team',root_id:'team',title:'同一会话',status:'completed',last_activity:now};
                const agents = Array.from({length:5},(_,index) => ({
                    id:'agent-'+index, root_id:'team', parent_id:index===4?'agent-0':'team',
                    status:'running', last_activity:now
                }));
                window.officeTeamFixture = {source_status:'ok',collected_at:now,projects:[],threads:[root,...agents]};
                window.officeSetSnapshot(window.officeTeamFixture, null, {});
                window.officeSetVisible(true);
            })()
            """)
        try await expect("Two nearby robots show under the same main chat", panel, view, """
            (() => {
                const cards = document.querySelectorAll('.chat-marker[data-thread-id]');
                const root = cards[0];
                const links = [...document.querySelectorAll('.agent-link[data-owner="team"]')];
                return cards.length===1 && root.dataset.threadId==='team' &&
                    root.querySelector('.chat-name').textContent.includes('同一会话') &&
                    root.getAttribute('aria-label').includes('5 个子 Agent') &&
                    links.length===2 && links.every(link => link.getBoundingClientRect().width>10) &&
                    root.querySelectorAll('.agent-node').length===3 &&
                    (matchMedia('(prefers-reduced-motion: reduce)').matches ||
                        links.every(link => getComputedStyle(link,'::after').animationName==='agent-signal'));
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeAgentAnchor = document.querySelector('.agent-link[data-agent="agent-0"]').style.left;
            window.officeTeamFixture.threads[0].status = 'waiting';
            window.officeTeamFixture.threads[5].status = 'waiting';
            window.officeSetSnapshot(window.officeTeamFixture, null, {});
            """)
        try await expect("A waiting agent has a visible link with no pulse", panel, view, """
            (() => {
                const link = document.querySelector('.agent-link[data-agent="agent-4"][data-status="waiting"]');
                return !!link && getComputedStyle(link,'::after').animationName==='none' &&
                    document.querySelector('.agent-link[data-agent="agent-0"]').style.left===window.officeAgentAnchor &&
                    document.querySelector('[data-thread-id="team"]').getAttribute('aria-label').includes('1 个等你确认');
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const fixture = window.officeTeamFixture;
                const neighbor = {id:'neighbor',root_id:'neighbor',title:'邻座',status:'running',
                    last_activity:fixture.collected_at};
                window.officeSetSnapshot({...fixture,threads:[...fixture.threads,neighbor]}, null, {});
            })()
            """)
        try await expect("A neighboring main desk takes precedence over an agent robot", panel, view, """
            document.querySelectorAll('.agent-link').length===1 &&
            !!document.querySelector('.agent-link[data-agent="agent-4"]') &&
            !!document.querySelector('[data-thread-id="neighbor"]')
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const fixture = window.officeTeamFixture;
                const extras = Array.from({length:9},(_,index) => ({
                    id:'seat-'+index,root_id:'seat-'+index,title:'其他会话',status:'running',
                    project_id:index<5?null:'p'+Math.floor((index-5)/2),last_activity:fixture.collected_at
                }));
                window.officeSetSnapshot({...fixture,threads:[...fixture.threads,...extras],
                    projects:[{id:'p0',name:'项目一'},{id:'p1',name:'项目二'}]}, null, {});
            })()
            """)
        try await expect("A crowded office uses the original compact team display", panel, view, """
            document.querySelectorAll('.chat-marker[data-thread-id]').length===10 &&
            !document.querySelector('.agent-link') &&
            !!document.querySelector('[data-thread-id="team"] .agent-node[data-status="waiting"]') &&
            document.querySelector('[data-thread-id="team"] .chat-team').textContent.includes('+')
            """)
        _ = try await view.evaluateJavaScript("window.officeSetVisible(false)")
        try await expect("A hidden panel pauses the agent signal", panel, view, """
            getComputedStyle(document.querySelector('[data-thread-id="team"] .agent-flow'),'::after').animationName==='none'
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const fixture = window.officeTeamFixture;
                const projectRoot = {id:'project-team',root_id:'project-team',project_id:'p',status:'running',
                    last_activity:fixture.collected_at};
                const agents = fixture.threads.slice(1).map(agent => ({
                    ...agent, root_id:projectRoot.id, parent_id:projectRoot.id
                }));
                window.officeSetSnapshot({...fixture,projects:[{id:'p',name:'团队项目'}],
                    threads:[projectRoot,...agents]}, null, {});
                window.officeSetVisible(true);
            })()
            """)
        try await expect("A project agent stays inside its own project area", panel, view, """
            (() => {
                const links = [...document.querySelectorAll('.agent-link[data-owner="project-team"]')];
                const root = document.querySelector('[data-thread-id="project-team"]');
                return links.length===1 && links[0].dataset.agent==='agent-4' &&
                    new DOMMatrix(getComputedStyle(links[0]).transform).a>0 &&
                    root.querySelectorAll('.agent-node').length>0;
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetVisible(false);
            delete window.officeTeamFixture;
            delete window.officeAgentAnchor;
            """)
    }

    @MainActor
    private static func button(_ action: OfficeToolbarAction, in panel: NSPanel) throws -> NSButton {
        guard let content = panel.contentView else { throw Failure("Native panel content is missing") }
        return try button(action, in: content)
    }

    @MainActor
    private static func button(_ action: OfficeToolbarAction, in content: NSView) throws -> NSButton {
        func find(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == action.rawValue { return button }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        guard let button = find(in: content) else {
            throw Failure("Native toolbar button is missing: \(action.rawValue)")
        }
        return button
    }

    @MainActor
    private static func checkSettings(_ office: OfficeApplication, _ panel: NSPanel, _ view: WKWebView,
                                      _ settings: URL) async throws {
        try button(.settings, in: panel).performClick(nil)
        try await expect("Settings load through the native bridge", panel, view, """
            document.querySelector('#office-settings').open &&
            document.querySelector('#close-settings').textContent === '返回' &&
            document.querySelector('[name=menu_bar_metric]').value === 'token_speed' &&
            !document.querySelector('#office-settings fieldset').disabled &&
            !document.querySelector('#save-settings')
            """)
        office.setOffscreenMenuUsage(Data(#"{"live_status":"ok","tokens_per_minute":12500,"today_status":"ok","today_tokens":342500}"#.utf8))
        let chineseMenu = office.offscreenMenuBar
        guard chineseMenu.title == "0 进行中 · 12.5K/min",
              chineseMenu.items.contains("最近 1 分钟：12,500 tokens/min"),
              chineseMenu.items.contains("设置…") else {
            throw Failure("The menu bar did not use the Chinese labels and token rate: \(chineseMenu)")
        }
        try await expect("Complex settings have localized help on hover and focus", panel, view, """
            (() => {
                const dialog = document.querySelector('#office-settings');
                const tooltip = document.querySelector('#settings-help-tooltip');
                const button = dialog.querySelector('[aria-describedby=help-menu-bar]');
                if (button.disabled) return false;
                button.dispatchEvent(new PointerEvent('pointerenter',{pointerType:'mouse'}));
                const bounds = dialog.getBoundingClientRect();
                const tip = tooltip.getBoundingClientRect();
                const hovered = !tooltip.hidden && tooltip.textContent.includes('最近 1 分钟') &&
                    tip.left>=bounds.left && tip.right<=bounds.right && tip.top>=bounds.top && tip.bottom<=bounds.bottom;
                button.dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse'}));
                const left = tooltip.hidden;
                button.focus();
                const focused = !tooltip.hidden && tooltip.textContent.includes('Token 速度');
                button.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
                return dialog.querySelectorAll('.setting-help').length===5 &&
                    hovered && left && focused && tooltip.hidden && dialog.open;
            })()
            """)
        try await expect("App settings show the version and login item", panel, view, """
            document.querySelector('#office-version').textContent === '0.1.0 (a1b2c3d4)' &&
            document.querySelector('#office-version').title === 'Git 提交 a1b2c3d4' &&
            !document.querySelector('#office-login-item').checked &&
            !document.querySelector('#office-login-item').disabled
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#office-login-item').click()")
        try await expect("Login item reflects enabling", panel, view, """
            document.querySelector('#office-login-item').checked &&
            !document.querySelector('#office-login-item').disabled
            """)
        _ = try await view.evaluateJavaScript("""
            document.querySelector('#office-login-item').click();
            document.querySelector('#check-office-update').click();
            """)
        try await expect("Unconfigured update channel is reported inline", panel, view, """
            !document.querySelector('#office-login-item').checked &&
            !document.querySelector('#office-login-item').disabled &&
            document.querySelector('#office-update-status').textContent === '尚未配置公开发布渠道。' &&
            document.querySelector('#office-release-actions').hidden
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const select = document.querySelector('[name=menu_bar_metric]');
                for (const value of ['plan_remaining','today_tokens']) {
                    select.value = value;
                    select.dispatchEvent(new Event('change',{bubbles:true}));
                }
            })()
            """)
        try await expect("Settings save through the native bridge", panel, view, """
            document.querySelector('#settings-feedback').textContent === '已保存' &&
            document.querySelector('[name=menu_bar_metric]').value === 'today_tokens'
            """)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        guard document?["menu_bar_metric"] as? String == "today_tokens" else {
            throw Failure("The settings change was not written to the temporary fixture")
        }
        guard office.offscreenMenuBar.title == "0 进行中 · 342.5K" else {
            throw Failure("The menu bar did not abbreviate the token count")
        }
        _ = try await view.evaluateJavaScript("""
            document.querySelector('#office-language + [role=combobox]').dispatchEvent(
                new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));
            """)
        try await expect("Language picker opens an in-panel list without the native select", panel, view, """
            (() => {
                const select = document.querySelector('#office-language');
                const combo = select.nextElementSibling;
                const list = document.getElementById(combo.getAttribute('aria-controls'));
                return select.hidden && combo.getAttribute('aria-expanded')==='true' &&
                    list?.closest('dialog')?.id==='office-settings' && !list.hidden &&
                    [...document.querySelectorAll('select')].every(source => source.hidden);
            })()
            """)
        _ = try await view.evaluateJavaScript("""
            (() => {
                const combo = document.querySelector('#office-language + [role=combobox]');
                for (const key of ['ArrowDown','Enter']) {
                    combo.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
                }
            })()
            """)
        try await expect("English is applied to the office and the custom choices", panel, view, """
            document.documentElement.lang==='en' &&
            document.querySelector('#settings-feedback').textContent==='Saved' &&
            document.querySelector('#office-settings-title').textContent==='Office settings' &&
            document.querySelector('#help-coordination').textContent.includes('automatic matching') &&
            document.querySelector('#close-settings').textContent==='Back' &&
            document.querySelector('#office-language').value==='en' &&
            document.querySelector('#menu-bar-metric + [role=combobox]').textContent==='Tokens today'
            """)
        let english = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let nativeSettings = try button(.settings, in: panel)
        guard english?["language"] as? String == "en", nativeSettings.toolTip == "Office Settings" else {
            throw Failure("English did not persist or reach the native toolbar")
        }
        let englishMenu = office.offscreenMenuBar
        guard englishMenu.title == "0 Active · 342.5K", englishMenu.items.contains("Today · 342,500 tokens"),
              englishMenu.items.contains("Settings…"), englishMenu.items.contains("Usage…") else {
            throw Failure("The menu bar did not switch with the settings language: \(englishMenu)")
        }
        _ = try await view.evaluateJavaScript("""
            (() => {
                const select = document.querySelector('#menu-bar-metric');
                select.value = 'token_speed';
                select.dispatchEvent(new Event('change',{bubbles:true}));
            })()
            """)
        try await expect("Token speed is saved with English selected", panel, view,
                         "document.querySelector('#settings-feedback').textContent==='Saved'")
        guard office.offscreenMenuBar.title == "0 Active · 12.5K/min" else {
            throw Failure("The menu bar did not retain the rate format in English")
        }
        _ = try await view.evaluateJavaScript("""
            (() => {
                const select = document.querySelector('#office-language');
                select.value = 'system';
                select.dispatchEvent(new Event('change',{bubbles:true}));
            })()
            """)
        let systemLanguage = OfficeLanguage.system.resolved
        try await expect("Follow system applies the resolved system language", panel, view, """
            document.documentElement.lang==='\(systemLanguage.rawValue)' &&
            document.querySelector('#settings-feedback').textContent==='\(systemLanguage.text("已保存", "Saved"))'
            """)
        guard (try OfficeSettings(url: settings).load())["language"] as? String == "system",
              office.offscreenMenuBar.title == systemLanguage.text("0 进行中 · 12.5K/min", "0 Active · 12.5K/min") else {
            throw Failure("The menu bar did not follow the system language")
        }
        _ = try await view.evaluateJavaScript("""
            (() => {
                const select = document.querySelector('#office-language');
                select.value = 'en';
                select.dispatchEvent(new Event('change',{bubbles:true}));
            })()
            """)
        try await expect("Restore English for the remaining settings checks", panel, view,
                         "document.documentElement.lang==='en' && document.querySelector('#settings-feedback').textContent==='Saved'")
        _ = try await view.evaluateJavaScript("""
            (() => {
                const section = document.querySelector('[name=coordination_section]');
                section.value = 'a'.repeat(129);
                section.dispatchEvent(new Event('change',{bubbles:true}));
            })()
            """)
        try await expect("The native settings error is shown in English", panel, view,
                         "document.querySelector('#settings-feedback').textContent==='The coordination section name is invalid.'")
        for (language, message) in [("zh-CN", "统筹分区名称无效。"), ("en", "The coordination section name is invalid.")] {
            try await setLanguage(language, view)
            try await expect("The existing native settings error follows the selected language", panel, view, """
                document.documentElement.lang==='\(language)' &&
                document.querySelector('#settings-feedback').textContent==='\(message)'
                """)
        }
        _ = try await view.evaluateJavaScript("""
            (() => {
                const assignments = document.querySelector('[name=thread_projects]');
                assignments.value = '{';
                assignments.dispatchEvent(new Event('input',{bubbles:true}));
                assignments.dispatchEvent(new Event('change',{bubbles:true}));
                const section = document.querySelector('[name=coordination_section]');
                section.value = 'New Coordination';
                section.dispatchEvent(new Event('input',{bubbles:true}));
                document.querySelector('#close-settings').click();
            })()
            """)
        for _ in 0..<80 {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
            if saved?["coordination_section"] as? String == "New Coordination" {
                guard (saved?["thread_projects"] as? [String: Any])?.isEmpty == true else {
                    throw Failure("Invalid JSON was persisted")
                }
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let textSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        guard textSettings?["coordination_section"] as? String == "New Coordination" else {
            throw Failure("Closing settings dropped a valid text edit")
        }
        _ = try await view.evaluateJavaScript("document.querySelector('#show-usage').click()")
        try await expect("The translated Usage tab opens the translated panel", panel, view, """
            !document.querySelector('#usage-panel').hidden &&
            document.querySelector('#show-office').textContent==='Office' &&
            document.querySelector('#show-usage').textContent==='Usage' &&
            document.querySelector('#usage-panel').getAttribute('aria-label')==='Token usage'
            """)
        _ = try await view.evaluateJavaScript("""
            window.officeSetUsage({quota_windows:[{window_minutes:300,remaining_percent:50,
                resets_at:new Date(Date.now()+125*60000-15000).toISOString()}]});
            """)
        try await expect("Quota reset countdown is translated", panel, view, """
            document.querySelector('#usage-plan-label').textContent==='5-hour quota remaining' &&
            document.querySelector('#usage-plan-countdown').textContent==='Resets in 2h 5m' &&
            document.querySelector('#usage-plan-second-label').parentElement.hidden
            """)
        try await checkOfficeLanguage(panel, view)
    }

    @MainActor
    private static func checkOfficeLanguage(_ panel: NSPanel, _ view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("""
            (() => {
                const id = '00000000-0000-0000-0000-000000000009';
                const now = new Date().toISOString();
                window.officeSetUsage({live_status:'ok',tokens_per_minute:1250000,today_status:'ok',today_tokens:3425000000,
                    today_estimated_usd:1234.56,today_priced_tokens:3425000000});
                window.officeSetSnapshot({source_status:'ok',collected_at:now,projects:[],
                    threads:[{id,root_id:id,status:'waiting',last_activity:now,title:'Codex chat',title_kind:'chat'}],
                    coordination:{source_status:'not_found'}}, null, {});
                window.officeLocateWaiting();
            })()
            """)
        for (language, title, status) in [("zh-CN", "Codex 会话", "等你确认"), ("en", "Codex chat", "Waiting for you")] {
            try button(.settings, in: panel).performClick(nil)
            try await expect("Settings opens for a language change", panel, view, "document.querySelector('#office-settings').open")
            try await setLanguage(language, view)
            try await expect("The office uses the saved language and fixed abbreviations", panel, view, """
                document.documentElement.lang==='\(language)' &&
                document.querySelector('#detail strong').textContent.startsWith('\(title) · ') &&
                document.querySelector('#detail span').textContent.includes('\(status)') &&
                document.querySelector('#office-token-rate').textContent==='1.3M/min' &&
                document.querySelector('#office-tokens-today').textContent==='3.4B tokens' &&
                document.querySelector('#office-cost-today').textContent==='≈ $1.2K' &&
                document.querySelector('#office-cost-today').title.includes('$1,234.56')
                """)
            _ = try await view.evaluateJavaScript("document.querySelector('#close-settings').click(); window.officeOpenCollaboration()")
            let note = language == "en" ? "Codex has no “Cross-project collaboration” section." : "Codex 中暂无「跨项目协作」分组"
            try await expect("The collaboration fallback also uses the saved language", panel, view, """
                document.querySelector('#collaboration-panel').open &&
                document.querySelector('#coordination-note').textContent.includes('\(note)')
                """)
            _ = try await view.evaluateJavaScript("document.querySelector('#dismiss-collaboration').click()")
        }
        _ = try await view.evaluateJavaScript("window.officeOpenUsage()")
    }

    @MainActor
    private static func setLanguage(_ language: String, _ view: WKWebView) async throws {
        _ = try await view.callAsyncJavaScript("""
            const select = document.querySelector('#office-language');
            select.value = language;
            select.dispatchEvent(new Event('change',{bubbles:true}));
            """, arguments: ["language": language], in: nil, contentWorld: .page)
    }

    @MainActor
    private static func checkDetailedUsage(_ office: OfficeApplication, _ panel: NSPanel, _ view: WKWebView) async throws {
        try await expect("The translated details entry is visible in Usage", panel, view, """
            document.querySelector('#open-usage-detail').textContent==='Usage details' &&
            document.querySelector('#open-usage-detail').getBoundingClientRect().width>0
            """)
        _ = try await view.evaluateJavaScript("document.querySelector('#open-usage-detail').click()")
        for _ in 0..<80 {
            if office.offscreenUsageDetails != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let (window, detail) = office.offscreenUsageDetails,
              window.styleMask.contains(.resizable), window.title == "Usage details" else {
            throw Failure("Usage did not open its own localized, resizable window")
        }
        try await expect("Detailed usage shows the same groups and the once-counted total", window, detail, """
            document.querySelectorAll('#usage-session-list > li').length===3 &&
            document.querySelector('#usage-total-tokens').textContent==='130 tokens' &&
            document.querySelector('#usage-total-cost').textContent.includes('$0.0001') &&
            document.querySelectorAll('.session-group-toggle[aria-expanded=true]').length===2 &&
            document.querySelector('#usage-session-list').textContent.includes('Unassigned automatic reviews')
            """)
        _ = try await detail.evaluateJavaScript("document.querySelector('#usage-toggle-groups').click()")
        try await expect("Detailed usage collapses every group", window, detail, """
            !document.querySelector('.session-group-toggle[aria-expanded=true]')
            """)
        _ = try await detail.evaluateJavaScript("document.querySelector('.session-group-toggle').click()")
        try await expect("Detailed usage can open just one group", window, detail, """
            document.querySelectorAll('.session-group-toggle[aria-expanded=true]').length===1
            """)
        _ = try await detail.evaluateJavaScript("""
            (() => {
                const project = document.querySelector('#usage-project');
                const model = document.querySelector('#usage-model');
                project.value = [...project.options].find(option => option.textContent==='project-2').value;
                model.value = [...model.options].find(option => option.textContent==='gpt-5-mini').value;
                document.querySelector('#usage-apply').click();
            })()
            """)
        try await expect("Project and model filters reach the collector", window, detail, """
            (() => {
                const rows = document.querySelectorAll('#usage-session-list [data-session-id]');
                return rows.length===1 && rows[0].textContent.includes('Usage chat 2');
            })()
            """)
        _ = try await detail.evaluateJavaScript("document.querySelector('#usage-session-list [data-session-id]').click()")
        try await expect("Session drilldown shows filtered usage inside the detail window", window, detail, """
            !document.querySelector('#session-detail').hidden &&
            document.querySelector('#session-title').textContent==='Usage chat 2' &&
            document.querySelector('#session-models').textContent.includes('gpt-5-mini') &&
            document.querySelector('#session-cost').textContent.includes('$0.0001') &&
            document.querySelector('#session-tokens').textContent.includes('60')
            """)
        try button(.settings, in: panel).performClick(nil)
        try await expect("Settings opens while the detailed usage window is loaded", panel, view, "document.querySelector('#office-settings').open")
        try await setLanguage("zh-CN", view)
        try await expect("The open detail window switches labels and dates while keeping the selected session", window, detail, """
            document.documentElement.lang==='zh-CN' && document.title==='详细用量' &&
            document.querySelector('#usage-apply').textContent==='应用筛选' &&
            document.querySelector('#session-date-range').textContent.includes('月') &&
            document.querySelector('#session-title').textContent==='Usage chat 2'
            """)
        guard window.title == "详细用量" else { throw Failure("The native detail window title did not switch to Chinese") }
        _ = try await detail.evaluateJavaScript("""
            document.querySelector('#usage-from').value = '';
            document.querySelector('#usage-apply').click();
            """)
        try await expect("Missing date validation uses the selected language", window, detail,
                         "document.querySelector('#usage-status').textContent==='请选择开始日期和结束日期。'")
        try await setLanguage("en", view)
        try await expect("The validation message is translated in the open detail window", window, detail, """
            document.documentElement.lang==='en' && document.title==='Usage details' &&
            document.querySelector('#usage-status').textContent==='Choose a start date and an end date.'
            """)
        guard window.title == "Usage details" else { throw Failure("The native detail window title did not switch back to English") }
        _ = try await detail.evaluateJavaScript("""
            document.querySelector('#usage-from').value = document.querySelector('#usage-to').value;
            document.querySelector('#usage-apply').click();
            """)
        try await expect("The date range can exclude both sessions", window, detail, """
            document.querySelectorAll('#usage-session-list [data-session-id]').length===0 &&
            document.querySelector('#usage-status').textContent==='No sessions match these filters.'
            """)
    }

    @MainActor
    private static func expect(_ label: String, _ panel: NSWindow, _ view: WKWebView, _ condition: String) async throws {
        for _ in 0..<80 {
            guard !panel.isVisible, !panel.isKeyWindow, !NSApp.isActive else {
                throw Failure("The offscreen UI test became visible or active")
            }
            if !view.isLoading, (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(label)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("UI test failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
