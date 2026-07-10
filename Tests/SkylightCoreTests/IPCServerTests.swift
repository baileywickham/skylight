import XCTest
@testable import SkylightCore

final class IPCServerTests: XCTestCase {
    private func tempSocketPath() -> String {
        // sockaddr_un paths are capped at 104 bytes; keep it short.
        "/tmp/skylight-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBufferPointer { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, 104)))
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "connect failed: \(String(cString: strerror(errno)))")
        return fd
    }

    private func roundTrip(_ fd: Int32, _ line: String) -> String {
        var out = line + "\n"
        _ = out.withUTF8 { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        XCTAssertGreaterThan(n, 0)
        return String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func testPingRoundTripAndSocketMode() throws {
        let path = tempSocketPath()
        let router = RequestRouter()
        router.register("ping") { try! Response.success(id: $0.id, result: ["pong": true]) }
        let server = IPCServer(socketPath: path, handler: router.route)
        try server.start()
        defer { server.stop() }

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.uint16Value, 0o600)

        let fd = connect(path)
        defer { close(fd) }
        let reply = roundTrip(fd, #"{"id":1,"method":"ping","params":{}}"#)
        let resp = try JSONDecoder().decode(Response.self, from: Data(reply.utf8))
        XCTAssertEqual(resp.id, 1)
        XCTAssertEqual(resp.result, .object(["pong": .bool(true)]))
    }

    func testStaleSocketIsUnlinkedAndRebound() throws {
        let path = tempSocketPath()
        FileManager.default.createFile(atPath: path, contents: nil) // stale file, nobody listening
        let server = IPCServer(socketPath: path, handler: { try! Response.success(id: $0.id, result: ["pong": true]) })
        try server.start() // must not throw
        server.stop()
    }

    func testLiveSocketRefusesSecondServer() throws {
        let path = tempSocketPath()
        let first = IPCServer(socketPath: path, handler: { try! Response.success(id: $0.id, result: ["pong": true]) })
        try first.start()
        defer { first.stop() }
        let second = IPCServer(socketPath: path, handler: { try! Response.success(id: $0.id, result: ["pong": true]) })
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? IPCError, .alreadyRunning)
        }
    }

    func testRequestsSerializeAcrossConnections() throws {
        let path = tempSocketPath()
        var concurrent = 0, maxConcurrent = 0
        let lock = NSLock()
        let server = IPCServer(socketPath: path) { req in
            lock.lock(); concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent); lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); concurrent -= 1; lock.unlock()
            return try! Response.success(id: req.id, result: ["pong": true])
        }
        try server.start()
        defer { server.stop() }

        let group = DispatchGroup()
        for i in 1...4 {
            group.enter()
            DispatchQueue.global().async {
                let fd = self.connect(path)
                _ = self.roundTrip(fd, "{\"id\":\(i),\"method\":\"ping\",\"params\":{}}")
                close(fd)
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(maxConcurrent, 1, "handler must run on one global serial queue")
    }

    func testPerRequestTimeout() throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path, requestTimeout: 0.2) { req in
            Thread.sleep(forTimeInterval: 1.0)
            return try! Response.success(id: req.id, result: ["pong": true])
        }
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }
        let reply = roundTrip(fd, #"{"id":5,"method":"ping","params":{}}"#)
        let resp = try JSONDecoder().decode(Response.self, from: Data(reply.utf8))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "timeout")
    }

    func testOversizedLineGetsProtocolError() throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path, handler: { try! Response.success(id: $0.id, result: ["pong": true]) })
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }
        var payload = [UInt8](repeating: 0x61, count: LineCodec.maxLineBytes + 2)
        payload[payload.count - 1] = 0x0A
        var written = 0
        while written < payload.count {
            let n = payload[written...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            written += n
        }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        XCTAssertGreaterThan(n, 0)
        let firstLine = Data(buf[0..<n]).prefix(while: { $0 != 0x0A })
        let resp = try JSONDecoder().decode(Response.self, from: firstLine)
        XCTAssertEqual(resp.error?.code, "protocol_error")
    }
}
