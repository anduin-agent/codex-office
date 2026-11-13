import Darwin
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private final class DesktopSocketFixture {
    let home = URL(fileURLWithPath: "/tmp/office-ipc-\(UUID().uuidString.prefix(12))", isDirectory: true)
    private var listener: Int32 = -1
    private var client: Int32 = -1

    init() throws {
        let directory = home.appendingPathComponent("ipc")
        let url = directory.appendingPathComponent("ipc.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try expect(listener >= 0, "Unable to create the fixture socket")
        var address = sockaddr_un()
        let path = url.path.utf8CString
        let length = MemoryLayout<sockaddr_un>.size
        try expect(path.count <= MemoryLayout.size(ofValue: address.sun_path), "Fixture socket path is too long")
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(length)) }
        }
        try expect(bound == 0, "Unable to bind the fixture socket")
        try expect(chmod(url.path, 0o660) == 0, "Unable to change socket permissions")
        try expect(listen(listener, 1) == 0, "Unable to listen on the fixture socket")
    }

    deinit {
        closeClient()
        if listener >= 0 { close(listener) }
        try? FileManager.default.removeItem(at: home)
    }

    func secure() throws {
        try expect(chmod(home.appendingPathComponent("ipc/ipc.sock").path, 0o600) == 0, "Unable to secure the socket")
    }

    func hasClient() -> Bool {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) == 1
    }

    func acceptClient() throws {
        try expect(hasClient(), "The observer did not connect to the fixture")
        client = accept(listener, nil, nil)
        try expect(client >= 0, "Unable to accept the observer")
        var noSignal: Int32 = 1
        try expect(setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                   "Unable to set fixture socket options")
    }

    func closeClient() {
        if client >= 0 { close(client) }
        client = -1
    }

    func receive() throws -> OfficeJSON {
        let length = try read(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        try expect(length > 0 && length <= 16_384, "Invalid frame size from observer")
        guard let message = try JSONSerialization.jsonObject(with: read(length)) as? OfficeJSON
        else { throw TestFailure(description: "Invalid message from observer") }
        return message
    }

    private func read(_ length: Int) throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            try expect(poll(&descriptor, 1, 500) == 1, "The observer did not send the expected message")
            var bytes = [UInt8](repeating: 0, count: length - buffer.count)
            let received = bytes.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            try expect(received > 0, "The observer closed the connection")
            buffer.append(contentsOf: bytes.prefix(received))
        }
        return buffer
    }

    static func frame(_ message: OfficeJSON) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + payload
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let size = send(client, base.advanced(by: sent), bytes.count - sent, 0)
                try expect(size > 0, "Unable to send a fixture message")
                sent += size
            }
        }
    }

    func write(_ message: OfficeJSON) throws { try write(Self.frame(message)) }
}

@main
enum DesktopAttentionTest {
    static func main() {
        do {
            try run()
            print("Desktop attention socket and waiting states passed")
        } catch {
            FileHandle.standardError.write(Data("Desktop attention test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let fixture = try DesktopSocketFixture()
        let identifier = UUID().uuidString.lowercased()
        let threads: Set<String> = [identifier]
        let untrusted = DesktopAttention(home: fixture.home)
        try expect(untrusted.poll(threads).isEmpty && !fixture.hasClient(), "A group-writable socket was accepted")
        try fixture.secure()

        let observer = DesktopAttention(home: fixture.home)
        try expect(observer.poll(threads).isEmpty, "Unexpected status before initialization")
        try fixture.acceptClient()
        let initialize = try fixture.receive()
        guard initialize["method"] as? String == "initialize",
              let requestID = initialize["requestId"] as? String,
              let params = initialize["params"] as? OfficeJSON, params["clientType"] as? String == "codex-office"
        else { throw TestFailure(description: "Incorrect observer initialization request") }
        try fixture.write(["type": "response", "requestId": requestID, "result": ["clientId": "office"]])
        try expect(observer.poll(threads).isEmpty, "Unexpected status before the first snapshot")

        func verifyFollow(_ following: Bool = true) throws {
            let message = try fixture.receive()
            guard message["method"] as? String == "thread-stream-following-changed",
                  let params = message["params"] as? OfficeJSON,
                  params["conversationId"] as? String == identifier, params["following"] as? Bool == following
            else { throw TestFailure(description: "Incorrect follow or unfollow message") }
        }
        try verifyFollow()

        func stream(_ change: OfficeJSON, host: String = "local") -> OfficeJSON {
            ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
             "sourceClientId": "desktop",
             "params": ["hostId": host, "conversationId": identifier, "change": change]]
        }
        func snapshot(_ revision: Int, flags: [String], host: String = "local") -> OfficeJSON {
            stream(["type": "snapshot", "revision": revision,
                    "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": flags]]], host: host)
        }
        func patches(_ revision: Int, base: Int, _ changes: [OfficeJSON]) -> OfficeJSON {
            stream(["type": "patches", "revision": revision, "baseRevision": base, "patches": changes])
        }

        let frame = try DesktopSocketFixture.frame(snapshot(10, flags: []))
        try fixture.write(frame.prefix(3))
        try expect(observer.poll(threads).isEmpty, "An incomplete frame changed the status")
        try fixture.write(frame.dropFirst(3))
        try expect(observer.poll(threads)[identifier]?.waiting == false, "The remaining frame bytes were not decoded")
        try fixture.write(snapshot(11, flags: ["waitingOnApproval"], host: "remote"))
        try expect(observer.poll(threads)[identifier]?.waiting == false, "Accepted status from a nonlocal host")

        for (revision, flag) in [(11, "waitingOnApproval"), (13, "waitingOnUserInput")] {
            let flagPath: [Any] = ["threadRuntimeStatus", "activeFlags", 0]
            try fixture.write(patches(revision, base: revision - 1, [["op": "add", "path": flagPath, "value": flag]]))
            try expect(observer.poll(threads)[identifier]?.waiting == true, "A waiting flag was not applied")
            try fixture.write(patches(revision, base: revision - 1, []))
            try expect(observer.poll(threads)[identifier]?.waiting == true, "A replay cleared the waiting status")
            try fixture.write(patches(revision + 1, base: revision, [["op": "remove", "path": flagPath]]))
            try expect(observer.poll(threads)[identifier]?.waiting == false, "Removing a waiting flag had no effect")
        }
        try fixture.write(patches(17, base: 16, []))
        try expect(observer.poll(threads).isEmpty, "A revision gap left stale status")
        try verifyFollow()
        try fixture.write(snapshot(17, flags: ["waitingOnUserInput"]))
        try expect(observer.poll(threads)[identifier]?.waiting == true, "Following again did not restore the status")

        try fixture.write(["type": "client-discovery-request", "requestId": "discovery"])
        _ = observer.poll(threads)
        let discovery = try fixture.receive()
        let response = discovery["response"] as? OfficeJSON
        try expect(discovery["requestId"] as? String == "discovery" && response?["canHandle"] as? Bool == false,
                   "The observer must not claim requests")
        try fixture.write(["type": "broadcast", "method": "client-status-changed",
                           "params": ["status": "disconnected", "clientId": "desktop"]])
        try expect(observer.poll(threads).isEmpty, "A disconnected desktop owner left stale status")
        try verifyFollow()
        try expect(observer.poll([]).isEmpty, "An unfollowed thread returned status")
        try verifyFollow(false)
        try expect(observer.poll(threads).isEmpty, "Unexpected status after following again")
        try verifyFollow()
        try fixture.write(snapshot(18, flags: ["waitingOnApproval"]))
        try expect(observer.poll(threads)[identifier]?.waiting == true, "Snapshot did not restore waiting status")
        fixture.closeClient()
        try expect(observer.poll(threads).isEmpty, "A disconnected socket left stale status")
        try expect(observer.poll(threads).isEmpty && !fixture.hasClient(), "Reconnect cooldown was bypassed")
    }
}
