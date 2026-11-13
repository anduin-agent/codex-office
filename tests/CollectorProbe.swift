import Foundation

/// The fixture runner keeps collectors alive across requests to test incremental indexing.
@main
enum CollectorProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        let home = OfficeCollectorPaths.codexHome(arguments[1])
        let settings = OfficeCollectorPaths.settings(arguments[2])
        if arguments.count == 5, arguments[3] == "--import-settings" {
            do {
                try settings.importFrom(OfficeCollectorPaths.fileURL(arguments[4]))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
            return
        }

        var suppliedStates: [String: DesktopThreadStatus] = [:]
        var polled = Set<String>()
        let activity = CodexActivity(home: home, settings: settings) { ids in
            polled = ids
            return suppliedStates.filter { ids.contains($0.key) }
        }
        let usage = CodexTokenUsage(home: home)
        while let line = readLine() {
            var response: OfficeJSON
            do {
                let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? OfficeJSON ?? [:]
                let now = (request["now"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
                switch request["operation"] as? String {
                case "snapshot":
                    suppliedStates = (request["attention"] as? [String: OfficeJSON] ?? [:]).compactMapValues { state in
                        guard let owner = state["owner"] as? String, let revision = state["revision"] as? Int,
                              let flags = state["flags"] as? [String] else { return nil }
                        return DesktopThreadStatus(owner: owner, revision: revision,
                                                   status: state["status"] as? String, flags: flags)
                    }
                    response = activity.scan(now: now)
                    if request["attention"] != nil { response["polled"] = polled.sorted() }
                case "tokenUsage":
                    let rates = (request["prices"] as? [String: OfficeJSON] ?? [:]).compactMapValues { values in
                        guard let input = values["input"] as? Double, let cached = values["cached_input"] as? Double,
                              let output = values["output"] as? Double else { return nil as OfficeTokenPrice? }
                        return OfficeTokenPrice(input: input, cachedInput: cached, output: output)
                    }
                    let prices = rates.isEmpty ? OfficePrices.empty : OfficePrices(updatedAt: "2026-11-13", rates: rates, longContext: [:])
                    response = usage.scan(now: now, budget: request["budget"] as? Double ?? 1.2, prices: prices)
                case "usageDay":
                    response = usage.dayDetails(request["day"] as? String ?? "")
                case "usageDetails":
                    let language = (request["language"] as? String).flatMap(OfficeLanguage.init(rawValue:)) ?? .simplifiedChinese
                    response = usage.detailedUsage(request["query"] as? OfficeJSON ?? [:], language: language, settings: settings)
                case "loadSettings", "saveSettings":
                    let office: OfficeJSON
                    if request["operation"] as? String == "saveSettings" {
                        guard let changes = request["changes"] as? OfficeJSON else {
                            throw OfficeSettings.InvalidSettings("办公室设置字段无效。", "The office settings contain unsupported fields.")
                        }
                        office = try settings.update(changes)
                    } else {
                        office = try settings.load()
                    }
                    response = ["office": office, "sidebar": readOfficeSidebar(home).0]
                default:
                    response = ["error": "未知测试请求"]
                }
            } catch {
                response = ["error": error.localizedDescription]
            }
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([0x0a]))
        }
    }
}
