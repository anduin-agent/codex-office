import Darwin
import Foundation

typealias OfficeJSON = [String: Any]

private let officeTimestampPattern = try! NSRegularExpression(
    pattern: #"\A(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:[.,]([0-9]+))?(Z|[+-]\d{2}:\d{2})\z"#
)

private let officeRolloutPattern = try! NSRegularExpression(pattern: "[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}")

func officeRolloutID(_ path: URL) -> String? {
    let name = path.lastPathComponent
    guard let match = officeRolloutPattern.matches(in: name, range: NSRange(name.startIndex..., in: name)).last,
          let range = Range(match.range, in: name) else { return nil }
    return String(name[range])
}

func officeCanonicalPath(_ value: Any?) -> String? {
    guard let path = value as? String, path.hasPrefix("/"), !path.contains("\0") else { return nil }
    if let physical = realpath(path, nil) {
        defer { free(physical) }
        return String(cString: physical)
    }

    // A file-change event may name a deleted or moved file. Resolve any symlink
    // in the existing prefix so its path still maps to the same physical project.
    var pending = Array(path.split(separator: "/").reversed())
    var components: [Substring] = []
    var traversedLinks = 0
    var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
    while let part = pending.popLast() {
        if part == "." { continue }
        if part == ".." {
            _ = components.popLast()
            continue
        }
        components.append(part)
        let candidate = "/" + components.joined(separator: "/")
        let count = buffer.withUnsafeMutableBytes { bytes in
            readlink(candidate, bytes.baseAddress!, bytes.count)
        }
        if count < 0 { continue }
        traversedLinks += 1
        guard traversedLinks <= 40, count < buffer.count,
              let target = String(bytes: buffer.prefix(count), encoding: .utf8) else { return nil }
        _ = components.popLast()
        if target.hasPrefix("/") { components.removeAll() }
        pending.append(contentsOf: target.split(separator: "/").reversed())
    }
    return "/" + components.joined(separator: "/")
}

func officeThreadID(_ value: Any?) -> String? {
    guard var text = value as? String else { return nil }
    if let id = UUID(uuidString: text) { return id.uuidString.lowercased() }
    if text.hasPrefix("urn:uuid:") { text.removeFirst(9) }
    if text.hasPrefix("{"), text.hasSuffix("}") { text = String(text.dropFirst().dropLast()) }
    let digits = text.filter { $0 != "-" }
    guard digits.utf8.count == 32,
          digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
    else { return nil }
    var groups: [Substring] = []
    var start = digits.startIndex
    for length in [8, 4, 4, 4, 12] {
        let end = digits.index(start, offsetBy: length)
        groups.append(digits[start..<end])
        start = end
    }
    return groups.joined(separator: "-").lowercased()
}

func officeValidText(_ value: Any?, limit: Int) -> Bool {
    guard let text = value as? String, text.unicodeScalars.count <= limit,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }
}

func officeValidSectionID(_ value: Any?) -> Bool {
    guard let text = value as? String else { return false }
    return officeValidText(text, limit: 128) && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func officeTimestamp(_ value: Any?) -> Date? {
    guard let timestamp = value as? String, timestamp.utf8.count <= 128,
          let match = officeTimestampPattern.firstMatch(in: timestamp, range: NSRange(timestamp.startIndex..., in: timestamp)),
          let day = Range(match.range(at: 1), in: timestamp),
          let time = Range(match.range(at: 2), in: timestamp),
          let zone = Range(match.range(at: 4), in: timestamp),
          let whole = try? Date.ISO8601FormatStyle().parse(timestamp[day] + "T" + timestamp[time] + timestamp[zone])
    else { return nil }
    guard let decimal = Range(match.range(at: 3), in: timestamp) else { return whole }
    let fraction = timestamp[decimal].prefix(6)
    guard let value = Double("0." + fraction) else { return nil }
    return whole.addingTimeInterval(value)
}

func officeISODate(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    let rounded = (seconds * 1_000_000).rounded() / 1_000_000
    let whole = floor(rounded)
    let fraction = Int(((rounded - whole) * 1_000_000).rounded())
    let prefix = Date(timeIntervalSince1970: whole).ISO8601Format().dropLast()
    return prefix + (fraction == 0 ? "" : String(format: ".%06d", fraction)) + "+00:00"
}
