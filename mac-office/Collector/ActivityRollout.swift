import CoreFoundation
import CryptoKit
import Darwin
import Foundation

private let activityLifecycle: Set<String> = ["task_started", "task_complete", "turn_aborted"]
private let activityMarkers = (Array(activityLifecycle) + ["session_meta", "item_completed", "token_count"])
    .map { Data(("\"" + $0 + "\"").utf8) }

func officeDigest(_ value: String, length: Int) -> String {
    String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
}

func activityPath(_ path: String, liesIn directory: String) -> Bool {
    path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
}

struct ActivityFileSignature: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: UInt64
    let seconds: Int
    let nanos: Int
    let regular: Bool

    init(path: URL) throws {
        var info = stat()
        let result = path.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.init(info)
    }

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = UInt64(max(0, info.st_size))
        seconds = info.st_mtimespec.tv_sec
        nanos = info.st_mtimespec.tv_nsec
        regular = (info.st_mode & S_IFMT) == S_IFREG
    }

    var modified: TimeInterval { TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000 }

    func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
}

struct ActivityRollout {
    private static let maxRecordBytes = 32 * 1024 * 1024

    private(set) var offset: UInt64 = 0
    private var signature: ActivityFileSignature?
    private var anchor: SHA256.Digest?
    private(set) var identity: String?
    private(set) var parent: String?
    private(set) var root: String?
    private(set) var workspace: String?
    private var created: Date?
    private(set) var last: Date?
    private var turn: String?
    private(set) var status = "idle"
    private(set) var terminal: Date?
    private(set) var tokenTotal: Int64?
    private var tokenAt: Date?
    private(set) var edits: [String: (date: Date, locations: Set<String>)] = [:]
    private(set) var dispatches: [String: Date] = [:]

    static func read(_ path: URL, signature: ActivityFileSignature, previous: Self?) throws -> Self {
        if let previous, previous.signature == signature { return previous }
        let descriptor = path.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              ActivityFileSignature(info).sameFile(as: signature) else { throw POSIXError(.EIO) }

        var rollout = Self()
        if let previous, let prior = previous.signature, prior.sameFile(as: signature),
           signature.size >= previous.offset,
           try contentSignature(file, offset: previous.offset) == previous.anchor {
            rollout = previous
        }
        try file.seek(toOffset: rollout.offset)
        var position = rollout.offset
        var pending = Data()
        var skippingRecord = false
        while position < signature.size {
            guard let chunk = try file.read(upToCount: Int(min(64 * 1024, signature.size - position))),
                  !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                let slice = chunk[start..<newline]
                if !skippingRecord, slice.count <= maxRecordBytes - pending.count {
                    if pending.isEmpty {
                        rollout.acceptLine(slice, path: path)
                    } else {
                        pending.append(contentsOf: slice)
                        rollout.acceptLine(pending, path: path)
                    }
                }
                pending.removeAll(keepingCapacity: false)
                skippingRecord = false
                start = chunk.index(after: newline)
                rollout.offset = position + UInt64(start - chunk.startIndex)
            }
            let tail = chunk[start...]
            if !skippingRecord, tail.count <= maxRecordBytes - pending.count {
                pending.append(contentsOf: tail)
            } else {
                pending.removeAll(keepingCapacity: false)
                skippingRecord = true
            }
            position += UInt64(chunk.count)
        }
        rollout.signature = signature
        rollout.anchor = try contentSignature(file, offset: rollout.offset)
        return rollout
    }

    private static func contentSignature(_ file: FileHandle, offset: UInt64) throws -> SHA256.Digest {
        let count = min(offset, 512)
        if count == 0 { return SHA256.hash(data: Data()) }
        try file.seek(toOffset: 0)
        let head = try file.read(upToCount: Int(count)) ?? Data()
        try file.seek(toOffset: offset - count)
        let tail = try file.read(upToCount: Int(count)) ?? Data()
        return SHA256.hash(data: head + tail)
    }

    private mutating func acceptLine(_ line: Data, path: URL) {
        guard activityMarkers.contains(where: { line.range(of: $0) != nil }),
              let row = (try? JSONSerialization.jsonObject(with: line)) as? OfficeJSON,
              let payload = row["payload"] as? OfficeJSON else { return }
        let envelope = row["type"] as? String
        if envelope == "session_meta" {
            guard identity == nil else { return }
            identity = officeThreadID(payload["id"]) ?? officeRolloutID(path)
            let source = payload["source"] as? OfficeJSON
            let subagent = source?["subagent"] as? OfficeJSON
            let spawn = subagent?["thread_spawn"] as? OfficeJSON
            let forked = ["forked_from_id", "forked_from_session_id"].contains {
                guard let value = payload[$0], !(value is NSNull) else { return false }
                return (value as? String)?.isEmpty != true
            }
            let spawnParent = officeThreadID(spawn?["parent_thread_id"])
            // A spawned agent can inherit the parent's context through a fork.
            if !forked || spawnParent != nil || payload["thread_source"] as? String == "subagent" {
                parent = officeThreadID(payload["parent_thread_id"]) ?? spawnParent
            }
            let recordedRoot = officeThreadID(payload["session_id"])
            root = parent == nil ? identity : (recordedRoot != identity ? recordedRoot ?? parent : parent)
            workspace = officeCanonicalPath(payload["cwd"])
            created = officeTimestamp(row["timestamp"]) ?? officeTimestamp(payload["timestamp"])
            last = created
            return
        }
        guard envelope == "event_msg", let identity, let stamp = officeTimestamp(row["timestamp"]),
              stamp >= (created ?? stamp), let kind = payload["type"] as? String else { return }
        let eventTurn = payload["turn_id"] as? String
        if activityLifecycle.contains(kind) {
            guard let eventTurn, !eventTurn.isEmpty else { return }
            if let thread = payload["thread_id"], !(thread is NSNull),
               (thread as? String)?.isEmpty != true, officeThreadID(thread) != identity { return }
            if kind == "task_started" {
                guard eventTurn != turn, stamp >= (last ?? stamp) else { return }
                turn = eventTurn
                status = "running"
                terminal = nil
                edits.removeAll()
            } else if (eventTurn == turn && status == "running") || turn == nil {
                turn = eventTurn
                status = kind == "task_complete" ? "completed" : "interrupted"
                terminal = stamp
            } else {
                return
            }
            last = max(stamp, last ?? stamp)
        } else if kind == "token_count" {
            if status == "running" { last = max(stamp, last ?? stamp) }
            let info = payload["info"] as? OfficeJSON
            let usage = info?["total_token_usage"] as? OfficeJSON
            if let raw = usage?["total_tokens"] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
               !["f", "d"].contains(String(cString: raw.objCType)), let total = raw as? Int64,
               total >= 0, stamp >= (tokenAt ?? stamp) {
                tokenTotal = total
                tokenAt = stamp
            }
        } else if kind == "item_completed", officeThreadID(payload["thread_id"]) == identity,
                  let eventTurn, !eventTurn.isEmpty, eventTurn == turn {
            last = max(stamp, last ?? stamp)
            if let item = payload["item"] as? OfficeJSON {
                acceptFileChange(item, date: stamp)
                if let executor = verifiedDispatch(item), executor != identity {
                    dispatches[executor] = max(stamp, dispatches[executor] ?? stamp)
                }
            }
        }
    }

    private mutating func acceptFileChange(_ item: OfficeJSON, date: Date) {
        guard item["type"] as? String == "FileChange", item["status"] as? String == "completed",
              let id = item["id"] as? String, !id.isEmpty, edits[id] == nil,
              let changes = item["changes"] as? OfficeJSON else { return }
        // Only file locations are needed. Diffs and tool content are discarded.
        var locations = Set<String>()
        for (rawPath, change) in changes {
            if let path = officeCanonicalPath(rawPath) { locations.insert(path) }
            if let move = officeCanonicalPath((change as? OfficeJSON)?["move_path"]) { locations.insert(move) }
        }
        if !locations.isEmpty { edits[id] = (date, locations) }
    }

    func crossEdits(projects: ActivityProjects, origin: String?) -> [OfficeJSON] {
        guard let origin, let identity, let turn else { return [] }
        var latest: [String: (date: Date, id: String)] = [:]
        for (itemID, edit) in edits {
            for location in edit.locations {
                guard let target = projects.match(location), target != origin else { continue }
                let id = officeDigest("\(identity):\(turn):\(itemID):\(target)", length: 32)
                if let previous = latest[target], (edit.date, id) <= (previous.date, previous.id) { continue }
                latest[target] = (edit.date, id)
            }
        }
        return latest.sorted { ($0.value.date, $0.value.id) < ($1.value.date, $1.value.id) }
            .map { ["id": $0.value.id, "project_id": $0.key, "at": officeISODate($0.value.date)] }
    }
}

private func verifiedDispatch(_ item: OfficeJSON) -> String? {
    guard item["type"] as? String == "McpToolCall", item["status"] as? String == "completed",
          item["server"] as? String == "codex_app", item["pluginId"] as? String == "codex-app-tools@openai-bundled",
          let tool = item["tool"] as? String, ["create_thread", "send_message_to_thread"].contains(tool),
          let result = item["result"] as? OfficeJSON, let failed = result["isError"] as? NSNumber,
          CFGetTypeID(failed) == CFBooleanGetTypeID(), !failed.boolValue,
          let contents = result["content"] as? [Any] else { return nil }
    var targets = Set<String>()
    for case let block as OfficeJSON in contents {
        guard block["type"] as? String == "text", let text = block["text"] as? String,
              text.unicodeScalars.count <= 8192,
              let receipt = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? OfficeJSON,
              let target = officeThreadID(receipt["threadId"]) else { continue }
        targets.insert(target)
    }
    guard targets.count == 1, let target = targets.first else { return nil }
    if tool == "send_message_to_thread" {
        let arguments = item["arguments"] as? OfficeJSON
        guard officeThreadID(arguments?["threadId"]) == target else { return nil }
    }
    return target
}
