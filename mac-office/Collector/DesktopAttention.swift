import CoreFoundation
import Darwin
import Foundation

struct DesktopThreadStatus: Sendable {
    let owner: String
    let revision: Int
    var status: String?
    var flags: [String]

    var waiting: Bool {
        status == "active" && flags.contains { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }
    }
}

/// Observe desktop conversation status without retaining messages or responding to actions.
final class DesktopAttention {
    private static let streamMethod = "thread-stream-state-changed"
    private static let followMethod = "thread-stream-following-changed"
    private static let streamVersion = 11
    private static let maxFrame = 32 * 1024 * 1024
    private static let ioTimeout: TimeInterval = 0.05
    private static let reconnectDelay: TimeInterval = 10

    private enum IPCError: Error {
        case invalidSocket, invalidFrame, initialization, disconnected, timeout
    }

    private let socketURL: URL
    private var socket: Int32 = -1
    private var buffer = Data()
    private var client: String?
    private var handshake: String?
    private var handshakeDeadline: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var following = Set<String>()
    private var states = [String: DesktopThreadStatus]()

    init(home: URL) {
        socketURL = home.appendingPathComponent("ipc").appendingPathComponent("ipc.sock")
    }

    deinit {
        if socket >= 0 { close(socket) }
    }

    /// If the desktop stream is unavailable, the caller uses the rollout status.
    func poll(_ threads: Set<String>) -> [String: DesktopThreadStatus] {
        let now = Self.uptime
        do {
            if socket < 0 {
                guard !threads.isEmpty, now >= retryAt else { return [:] }
                try connect(now: now)
            }
            if client == nil, now > handshakeDeadline {
                throw IPCError.initialization
            }
            try drain(threads)
            if let client, following != threads {
                try follow(threads, client: client)
                try drain(threads)
            }
        } catch {
            disconnect()
        }
        return states.filter { threads.contains($0.key) }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func connect(now: TimeInterval) throws {
        var address = sockaddr_un()
        let length = try socketURL.withUnsafeFileSystemRepresentation { path -> socklen_t in
            guard let path else { throw IPCError.invalidSocket }
            var info = stat()
            guard lstat(path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0
            else { throw IPCError.invalidSocket }

            let pathBytes = strlen(path) + 1
            guard pathBytes <= MemoryLayout.size(ofValue: address.sun_path),
                  let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)
            else { throw IPCError.invalidSocket }
            let length = pathOffset + pathBytes
            address.sun_len = UInt8(length)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                bytes.copyBytes(from: UnsafeRawBufferPointer(start: path, count: pathBytes))
            }
            return socklen_t(length)
        }

        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var noSignal: Int32 = 1
        guard socket >= 0, fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(socket, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw IPCError.invalidSocket }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw IPCError.invalidSocket }
            guard try waitFor(Int16(POLLOUT), deadline: now + Self.ioTimeout) else { throw IPCError.timeout }
            var connectionError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &connectionError, &size) == 0, connectionError == 0
            else { throw IPCError.invalidSocket }
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(socket, &peerUID, &peerGID) == 0, peerUID == getuid() else { throw IPCError.invalidSocket }

        let requestID = UUID().uuidString.lowercased()
        handshake = requestID
        handshakeDeadline = now + 5
        try send([
            "type": "request", "method": "initialize", "version": 0,
            "requestId": requestID, "sourceClientId": "initializing-client",
            "params": ["clientType": "codex-office"],
        ])
    }

    private func disconnect() {
        if socket >= 0 { close(socket) }
        socket = -1
        client = nil
        handshake = nil
        buffer.removeAll()
        following.removeAll()
        states.removeAll()
        retryAt = Self.uptime + Self.reconnectDelay
    }

    private func waitFor(_ events: Int16, deadline: TimeInterval) throws -> Bool {
        var descriptor = pollfd(fd: socket, events: events, revents: 0)
        while true {
            let remaining = deadline - Self.uptime
            guard remaining > 0 else { return false }
            let result = Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1_000)))
            if result >= 0 { return result > 0 }
            guard errno == EINTR else { throw IPCError.disconnected }
        }
    }

    private func send(_ message: OfficeJSON) throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var size = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)
        let deadline = Self.uptime + Self.ioTimeout
        try frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(socket, base.advanced(by: sent), bytes.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard try waitFor(Int16(POLLOUT), deadline: deadline) else { throw IPCError.timeout }
                } else {
                    throw IPCError.disconnected
                }
            }
        }
    }

    private func follow(_ threads: Set<String>, client: String) throws {
        for identifier in following.symmetricDifference(threads).sorted() {
            let enabled = threads.contains(identifier)
            try send([
                "type": "broadcast", "method": Self.followMethod, "version": 1, "sourceClientId": client,
                "params": ["hostId": "local", "conversationId": identifier, "following": enabled],
            ])
            if enabled {
                following.insert(identifier)
            } else {
                following.remove(identifier)
                states.removeValue(forKey: identifier)
            }
        }
    }

    private func drain(_ threads: Set<String>) throws {
        let deadline = Self.uptime + Self.ioTimeout
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while Self.uptime < deadline {
            if buffer.count >= 4 {
                let size = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
                guard size > 0, size <= Self.maxFrame else { throw IPCError.invalidFrame }
                if buffer.count >= size + 4 {
                    let start = buffer.startIndex
                    let payload = buffer[(start + 4)..<(start + 4 + size)]
                    let message = try JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)
                    buffer.removeFirst(size + 4)
                    if let message = message as? OfficeJSON { try accept(message, threads: threads) }
                    continue
                }
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // A partial snapshot can outgrow the kernel receive buffer.
                guard !buffer.isEmpty, try waitFor(Int16(POLLIN), deadline: deadline) else { return }
            } else {
                throw IPCError.disconnected
            }
        }
    }

    private func accept(_ message: OfficeJSON, threads: Set<String>) throws {
        let type = message["type"] as? String
        if client == nil {
            if type == "response", let handshake, message["requestId"] as? String == handshake {
                guard let result = message["result"] as? OfficeJSON, let clientID = result["clientId"] as? String
                else { throw IPCError.initialization }
                client = clientID
                self.handshake = nil
            }
            return
        }
        if type == "client-discovery-request", let requestID = message["requestId"] as? String {
            try send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        guard type == "broadcast", let params = message["params"] as? OfficeJSON else { return }

        let method = message["method"] as? String
        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let disconnectedClient = params["clientId"] as? String {
            for identifier in states.keys.filter({ states[$0]?.owner == disconnectedClient }) {
                states.removeValue(forKey: identifier)
                following.remove(identifier)
            }
            return
        }

        guard method == Self.streamMethod, Self.integer(message["version"]) == Self.streamVersion,
              params["hostId"] as? String == "local", let identifier = params["conversationId"] as? String,
              threads.contains(identifier), following.contains(identifier),
              let owner = message["sourceClientId"] as? String, let change = params["change"] as? OfficeJSON,
              let revision = Self.integer(change["revision"])
        else { return }
        let previous = states[identifier]
        switch change["type"] as? String {
        case "snapshot":
            guard let snapshot = change["conversationState"] as? OfficeJSON else { return }
            if let previous, previous.owner == owner, revision < previous.revision { return }
            let (status, flags) = Self.runtimeStatus(snapshot["threadRuntimeStatus"])
            states[identifier] = DesktopThreadStatus(owner: owner, revision: revision, status: status, flags: flags)
        case "patches":
            guard let patches = change["patches"] as? [Any] else { return }
            if let previous, previous.owner == owner, revision <= previous.revision { return }
            guard var updated = previous, updated.owner == owner, updated.revision == Self.integer(change["baseRevision"]) else {
                states.removeValue(forKey: identifier)
                following.remove(identifier)
                return
            }
            Self.apply(patches, to: &updated)
            states[identifier] = DesktopThreadStatus(owner: owner, revision: revision, status: updated.status, flags: updated.flags)
        default:
            return
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let kind = String(cString: number.objCType).first, kind != "f", kind != "d"
        else { return nil }
        return number as? Int
    }

    private static func runtimeStatus(_ value: Any?) -> (String?, [String]) {
        guard let value = value as? OfficeJSON, let status = value["type"] as? String else { return (nil, []) }
        return (status, value["activeFlags"] as? [String] ?? [])
    }

    private static func apply(_ patches: [Any], to state: inout DesktopThreadStatus) {
        for case let patch as OfficeJSON in patches {
            guard let path = patch["path"] as? [Any], path.first as? String == "threadRuntimeStatus",
                  let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation)
            else { continue }
            let value = operation == "remove" ? nil : patch["value"]
            switch path.count {
            case 1:
                (state.status, state.flags) = runtimeStatus(value)
            case 2 where path[1] as? String == "type":
                state.status = value as? String
            case 2 where path[1] as? String == "activeFlags":
                state.flags = value as? [String] ?? []
            case 3 where path[1] as? String == "activeFlags":
                guard let index = integer(path[2]), index >= 0 else { continue }
                if operation == "remove", index < state.flags.count {
                    state.flags.remove(at: index)
                } else if let flag = value as? String {
                    if operation == "add", index <= state.flags.count {
                        state.flags.insert(flag, at: index)
                    } else if operation == "replace", index < state.flags.count {
                        state.flags[index] = flag
                    }
                }
            default:
                continue
            }
        }
    }
}
