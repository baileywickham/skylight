import XCTest
@testable import SkylightCore

/// End-to-end concurrency through a real socket.
///
/// The scheduler's own tests prove its admission rules, but they cannot catch a
/// bottleneck ELSEWHERE in the path — which is exactly what happened: requests
/// from one client arrive on one connection, and handling them in order there
/// serialized everything no matter what the scheduler allowed. These tests pin
/// the behavior at the layer a client actually observes.
final class IPCConcurrencyTests: XCTestCase {
    private func tempSocketPath() -> String {
        "/tmp/skylight-conc-\(UInt32.random(in: 0..<UInt32.max)).sock"
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
        var on: Int32 = 1
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)), 0)
        return fd
    }

    /// Server whose handler blocks for `holdMs`, so overlap is measurable.
    private func makeServer(path: String, holdMs: UInt32,
                            classify: @escaping (Request) -> RequestClass) -> IPCServer {
        let router = RequestRouter()
        router.register("work") { req in
            usleep(holdMs * 1000)
            return (try? Response.success(id: req.id, result: ["done": true]))
                ?? .failure(id: req.id, code: .protocolError, message: "encode")
        }
        return IPCServer(socketPath: path, classify: classify, handler: router.route)
    }

    /// Reads until `count` response lines have arrived (they may be out of order).
    private func readResponses(_ fd: Int32, count: Int) -> [String] {
        var lines: [String] = []
        var pending = ""
        var buf = [UInt8](repeating: 0, count: 65536)
        while lines.count < count {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending += String(decoding: buf[0..<n], as: UTF8.self)
            while let idx = pending.firstIndex(of: "\n") {
                lines.append(String(pending[pending.startIndex..<idx]))
                pending = String(pending[pending.index(after: idx)...])
            }
        }
        return lines
    }

    private func send(_ fd: Int32, id: Int, app: String) {
        var line = "{\"id\":\(id),\"method\":\"work\",\"params\":{\"app\":\"\(app)\"}}\n"
        _ = line.withUTF8 { write(fd, $0.baseAddress, $0.count) }
    }

    /// Two requests for different apps, sent down ONE connection, must overlap.
    func testDifferentKeysOverlapOnOneConnection() throws {
        let path = tempSocketPath()
        let server = makeServer(path: path, holdMs: 400) { req in
            let app = (try? req.decodeParams([String: String].self))?["app"] ?? "?"
            return .keyed(app)
        }
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        let start = Date()
        send(fd, id: 1, app: "Notes")
        send(fd, id: 2, app: "Safari")
        let responses = readResponses(fd, count: 2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(responses.count, 2)
        XCTAssertLessThan(elapsed, 0.7,
                          "two 400ms requests for different apps should overlap, not queue (took \(elapsed)s)")
    }

    /// Same app must still serialize — the invariant that makes per-app state
    /// safe without locking it.
    func testSameKeySerializesOnOneConnection() throws {
        let path = tempSocketPath()
        let server = makeServer(path: path, holdMs: 300) { req in
            let app = (try? req.decodeParams([String: String].self))?["app"] ?? "?"
            return .keyed(app)
        }
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        let start = Date()
        send(fd, id: 1, app: "Notes")
        send(fd, id: 2, app: "Notes")
        let responses = readResponses(fd, count: 2)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(responses.count, 2)
        XCTAssertGreaterThan(elapsed, 0.55,
                             "two requests for one app must not overlap (took \(elapsed)s)")
    }

    /// The default classifier keeps the original fully-serialized behavior, so
    /// a server built without one is unchanged.
    func testDefaultClassifierSerializesEverything() throws {
        let path = tempSocketPath()
        let router = RequestRouter()
        router.register("work") { req in
            usleep(300_000)
            return (try? Response.success(id: req.id, result: ["done": true]))
                ?? .failure(id: req.id, code: .protocolError, message: "encode")
        }
        let server = IPCServer(socketPath: path, handler: router.route)
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        let start = Date()
        send(fd, id: 1, app: "Notes")
        send(fd, id: 2, app: "Safari")
        _ = readResponses(fd, count: 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.55,
                             "without a classifier every request is exclusive")
    }

    /// Concurrent handling must not corrupt the framing: every response is a
    /// complete, parseable line carrying its own id.
    func testResponsesStayWellFormedUnderConcurrency() throws {
        let path = tempSocketPath()
        let server = makeServer(path: path, holdMs: 50) { req in
            let app = (try? req.decodeParams([String: String].self))?["app"] ?? "?"
            return .keyed(app)
        }
        try server.start()
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        for id in 1...16 { send(fd, id: id, app: "app-\(id)") }
        let responses = readResponses(fd, count: 16)
        XCTAssertEqual(responses.count, 16)

        var seen = Set<Int>()
        for line in responses {
            let decoded = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
            XCTAssertTrue(decoded.ok, "response \(decoded.id) failed")
            seen.insert(decoded.id)
        }
        XCTAssertEqual(seen, Set(1...16), "every request must get exactly one response")
    }
}
