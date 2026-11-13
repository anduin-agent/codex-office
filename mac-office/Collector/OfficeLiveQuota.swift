import CoreFoundation
import Darwin
import Foundation

struct OfficeLiveQuota: Sendable {
    struct Window: Sendable {
        let minutes: Int
        let remaining: Double
        let resets: Date?

        var payload: OfficeJSON {
            ["window_minutes": minutes, "remaining_percent": remaining,
             "resets_at": resets.map(officeISODate) as Any? ?? NSNull()]
        }
    }

    let account: String?
    let plan: String?
    // nil means the read failed. An empty result is a successful read with no windows.
    let windows: [Window]?
    let sampledAt: Date

    private struct Unavailable: Error {}

    static func read(executable: URL?, home: URL) async -> Self {
        let task = Task.detached(priority: .utility) { () -> Self in
            guard let executable else { return failed() }
            return readProcess(executable: executable, home: home)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func failed(account: String? = nil, plan: String? = nil) -> Self {
        Self(account: account, plan: plan, windows: nil, sampledAt: Date())
    }

    private static func readProcess(executable: URL, home: URL) -> Self {
        guard !Task.isCancelled else { return failed() }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return failed() }
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return failed() }
        defer {
            try? writer.close()
            try? reader.close()
            if process.isRunning { process.terminate() }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var buffer = Data()
        func send(_ message: OfficeJSON) throws {
            guard !Task.isCancelled else { throw CancellationError() }
            try writer.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
        }
        func response(_ id: Int) throws -> OfficeJSON {
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? OfficeJSON,
                          reply["id"] as? Int == id else { continue }
                    guard let result = reply["result"] as? OfficeJSON else { throw Unavailable() }
                    return result
                }
                let ready = poll(&descriptor, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw Unavailable() }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let length = Darwin.read(descriptor.fd, &bytes, bytes.count)
                if length < 0 && errno == EINTR { continue }
                guard length > 0, buffer.count + length <= 1_048_576 else { throw Unavailable() }
                buffer.append(contentsOf: bytes.prefix(length))
            }
            throw Unavailable()
        }

        var account: String?
        var plan: String?
        do {
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex-office", "title": "Codex Office", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true],
            ]])
            _ = try response(1)
            try send(["method": "initialized"])
            try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
            let identity = try response(2)
            guard let login = identity["account"] as? OfficeJSON, login["type"] as? String == "chatgpt" else {
                return failed()
            }
            account = accountID((identity["workspaceRouting"] as? OfficeJSON)?["chatgptAccountId"])
            plan = login["planType"] as? String
            try send(["id": 3, "method": "account/rateLimits/read"])
            return try decode(response(3), account: account, plan: plan)
        } catch {
            return failed(account: account, plan: plan)
        }
    }

    private static func accountID(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func decode(_ result: OfficeJSON, account: String?, plan: String?) throws -> Self {
        let reportedAccount = accountID(result["accountId"])
        if let reportedAccount, let account, reportedAccount != account { return failed() }
        let byID = result["rateLimitsByLimitId"] as? [String: OfficeJSON]
        let legacy = result["rateLimits"] as? OfficeJSON
        let activeAccount = reportedAccount ?? account
        if let limits = byID?["codex"] { return decodedWindows(limits, account: activeAccount, plan: plan) }
        guard let legacy else { throw Unavailable() }
        if let id = legacy["limitId"] as? String, !id.isEmpty, id != "codex" {
            return Self(account: activeAccount, plan: plan, windows: [], sampledAt: Date())
        }
        return decodedWindows(legacy, account: activeAccount, plan: plan)
    }

    private static func decodedWindows(_ limits: OfficeJSON, account: String?, plan: String?) -> Self {
        var seen = Set<Int>()
        let windows: [Window] = ["primary", "secondary"].compactMap { key in
            guard let raw = limits[key] as? OfficeJSON,
                  let duration = raw["windowDurationMins"] as? NSNumber, CFGetTypeID(duration) != CFBooleanGetTypeID(),
                  let minutes = Int(exactly: duration.doubleValue), (1...525_600).contains(minutes),
                  let used = raw["usedPercent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
                  (0...100).contains(used.doubleValue), seen.insert(minutes).inserted else { return nil }
            let resets = (raw["resetsAt"] as? NSNumber).flatMap { value -> Date? in
                let seconds = value.doubleValue
                guard CFGetTypeID(value) != CFBooleanGetTypeID(), seconds > 0, seconds < 253_402_300_800 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            return Window(minutes: minutes, remaining: 100 - used.doubleValue, resets: resets)
        }
        return Self(account: account, plan: limits["planType"] as? String ?? plan,
                    windows: windows.sorted { $0.minutes < $1.minutes }, sampledAt: Date())
    }

    func displayPayload(_ local: OfficeJSON, now: Date = Date()) -> OfficeJSON {
        var payload = local
        let sameAccount = account.map { $0 == local["quota_account"] as? String } ?? false
        if let windows {
            let active = windows.filter { $0.resets.map { $0 > now } ?? true }
            let localWindows = sameAccount ? local["quota_windows"] as? [OfficeJSON] ?? [] : []
            let rows = active.map { window -> OfficeJSON in
                let live = window.payload
                guard let reset = live["resets_at"] as? String,
                      let matching = localWindows.first(where: {
                          $0["window_minutes"] as? Int == window.minutes && $0["resets_at"] as? String == reset
                      }) else { return live }
                // Estimates remain paired with their log sample. Only carry them when the percentages also agree.
                guard matching["remaining_percent"] as? Double == window.remaining else { return live }
                return matching.merging(live) { _, current in current }
            }
            payload["quota"] = rows.last as Any? ?? NSNull()
            payload["quota_windows"] = rows
            payload["quota_closed_windows"] = [] as [OfficeJSON]
            payload["quota_plan"] = plan as Any? ?? NSNull()
            payload["quota_sampled_at"] = officeISODate(sampledAt)
            payload["quota_source"] = "live"
        } else if sameAccount {
            payload["quota_source"] = "fallback"
        } else {
            payload["quota"] = NSNull()
            payload["quota_windows"] = [] as [OfficeJSON]
            payload["quota_closed_windows"] = [] as [OfficeJSON]
            payload["quota_plan"] = plan as Any? ?? NSNull()
            payload["quota_sampled_at"] = NSNull()
            payload["quota_source"] = "unavailable"
        }
        return payload
    }
}
