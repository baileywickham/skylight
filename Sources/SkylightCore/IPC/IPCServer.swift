import Foundation
import Darwin

public enum IPCError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
}

/// Unix-domain-socket server speaking one JSON object per line.
///
/// Requests are admitted by `ActuationScheduler`, which decides what may
/// overlap: background work against different apps runs in parallel, while
/// foreground work (which activates apps and moves the real cursor) runs alone.
/// The default classifier marks EVERYTHING exclusive, so a server constructed
/// without one behaves exactly like the original single-serial-queue design.
public final class IPCServer {
    public typealias Handler = (Request) -> Response

    private let socketPath: String
    private let requestTimeout: TimeInterval
    private let handler: Handler
    private let classify: (Request) -> RequestClass
    private let scheduler = ActuationScheduler()
    /// Requests dispatch concurrently and then queue for admission inside the
    /// scheduler, so a request waiting on one app does not hold up another.
    private let actuationQueue = DispatchQueue(label: "com.skylight.actuation",
                                               attributes: .concurrent)
    /// Per-request handling, so one connection's requests do not serialize on
    /// its reader thread. Separate from `actuationQueue` because a block here
    /// BLOCKS while waiting for its request to finish (that wait is what
    /// enforces the per-request timeout), and it must not consume the capacity
    /// the actuation work itself needs. Both are bounded in practice by the
    /// number of live clients.
    private let connectionQueue = DispatchQueue(label: "com.skylight.connection",
                                                attributes: .concurrent)
    /// Guards `listenFD`, which is touched from start()/stop() and the accept thread.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1

    private var isListening: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenFD >= 0
    }

    public init(socketPath: String, requestTimeout: TimeInterval = 30,
                classify: @escaping (Request) -> RequestClass = { _ in .exclusive },
                handler: @escaping Handler) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        self.classify = classify
        self.handler = handler
    }

    public func start() throws {
        try Self.removeStaleSocket(at: socketPath)
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketFailed(errno) }
        var addr = Self.sockaddr(for: socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw IPCError.bindFailed(errno) }
        chmod(socketPath, 0o600) // owner-only: the socket grants full input control
        // Backlog well above the number of clients ever expected: a burst of
        // connects that overflows it is refused outright (ECONNREFUSED), and a
        // parallel agent fleet opening several sockets at once is now a normal
        // pattern. 16 was demonstrably too small — under CPU load the accept
        // loop fell behind a 20-connect burst and connections were refused.
        guard listen(fd, SOMAXCONN) == 0 else { close(fd); throw IPCError.listenFailed(errno) }

        stateLock.lock()
        listenFD = fd
        stateLock.unlock()

        Thread.detachNewThread { [weak self] in
            while let self, self.isListening {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                // A peer that disconnects before reading must yield EPIPE, not SIGPIPE.
                // macOS rejects this setsockopt with EINVAL when the peer already
                // closed before we got here, and such a socket can never be made safe
                // to write to: Darwin has no MSG_NOSIGNAL, and it raises SIGPIPE
                // process-directed (a per-thread mask only redirects the kill to
                // another thread). So a socket whose sockopt failed is served
                // read-only — its responses are dropped, which the vanished peer
                // could never have read anyway.
                var on: Int32 = 1
                let writable = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on,
                                          socklen_t(MemoryLayout<Int32>.size)) == 0
                Thread.detachNewThread { self.serve(fd: client, writable: writable) }
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR) // wake a blocked accept() before closing
            close(fd)
        }
        unlink(socketPath)
    }

    /// If a socket file exists: connect to it. Connectable → another daemon is
    /// live (refuse to start). Not connectable → stale crash leftover, unlink it.
    public static func removeStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr(for: path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { throw IPCError.alreadyRunning }
        unlink(path)
    }

    private static func sockaddr(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBufferPointer { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, 104)))
            }
        }
        return addr
    }

    /// `writable` is false when SO_NOSIGPIPE could not be applied (peer already
    /// gone by accept time): the request is still read and handled, but nothing
    /// is ever written to the socket, because any write could raise a fatal,
    /// process-directed SIGPIPE.
    private func serve(fd: Int32, writable: Bool) {
        // Requests from ONE connection are handled concurrently — a single
        // client driving several apps (`Promise.all`) sends them down one
        // socket, so handling them in order here would serialize everything and
        // make ActuationScheduler's per-app parallelism unobservable. What may
        // actually overlap is still decided centrally by the scheduler; this
        // only stops the connection itself from being the bottleneck.
        //
        // Responses may therefore come back out of order, which the protocol
        // already allows: every response carries its request id and clients
        // match on it.
        let inFlight = DispatchGroup()
        // Serializes writes so two responses can never interleave mid-line.
        let writeLock = NSLock()
        // Wait for in-flight handlers before closing: they write to this fd.
        defer {
            inFlight.wait()
            close(fd)
        }
        let codec = LineCodec()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            let lines: [Data]
            do {
                lines = try codec.append(Data(buf[0..<n]))
            } catch {
                if writable {
                    writeLock.lock()
                    send(fd, .failure(id: 0, code: .protocolError, message: "request line exceeds \(LineCodec.maxLineBytes) bytes"))
                    writeLock.unlock()
                }
                return
            }
            for line in lines where !line.isEmpty {
                inFlight.enter()
                connectionQueue.async { [self] in
                    defer { inFlight.leave() }
                    let response = handle(line: line)
                    guard writable else { return }
                    writeLock.lock()
                    send(fd, response)
                    writeLock.unlock()
                }
            }
        }
    }

    private func handle(line: Data) -> Response {
        guard let request = try? JSONDecoder().decode(Request.self, from: line) else {
            return .failure(id: 0, code: .protocolError, message: "malformed request line")
        }
        var response: Response?
        let done = DispatchSemaphore(value: 0)
        let requestClass = classify(request)
        actuationQueue.async { [handler, scheduler] in
            scheduler.run(requestClass) {
                response = handler(request)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + requestTimeout) == .timedOut {
            return .failure(id: request.id, code: .timeout,
                            message: "request '\(request.method)' exceeded \(requestTimeout)s")
        }
        return response!
    }

    private func send(_ fd: Int32, _ response: Response) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return // EPIPE etc.: peer is gone, drop the response
                }
                sent += n
            }
        }
    }
}
