import Foundation
import Darwin

public enum IPCError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
}

/// Unix-domain-socket server speaking one JSON object per line.
/// All handlers run on ONE global serial queue across every connection, so
/// actuation from concurrent (or orphaned) clients can never interleave.
public final class IPCServer {
    public typealias Handler = (Request) -> Response

    private let socketPath: String
    private let requestTimeout: TimeInterval
    private let handler: Handler
    /// The global actuation queue: every request from every connection lands here.
    private let actuationQueue = DispatchQueue(label: "com.skylight.actuation")
    private var listenFD: Int32 = -1

    public init(socketPath: String, requestTimeout: TimeInterval = 30, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    public func start() throws {
        try Self.removeStaleSocket(at: socketPath)
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw IPCError.socketFailed(errno) }
        var addr = Self.sockaddr(for: socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(listenFD); throw IPCError.bindFailed(errno) }
        chmod(socketPath, 0o600) // owner-only: the socket grants full input control
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw IPCError.listenFailed(errno) }

        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while let self, self.listenFD >= 0 {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                Thread.detachNewThread { self.serve(fd: client) }
            }
        }
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
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

    private func serve(fd: Int32) {
        defer { close(fd) }
        let codec = LineCodec()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            let lines: [Data]
            do {
                lines = try codec.append(Data(buf[0..<n]))
            } catch {
                send(fd, .failure(id: 0, code: .protocolError, message: "request line exceeds \(LineCodec.maxLineBytes) bytes"))
                return
            }
            for line in lines where !line.isEmpty {
                send(fd, handle(line: line))
            }
        }
    }

    private func handle(line: Data) -> Response {
        guard let request = try? JSONDecoder().decode(Request.self, from: line) else {
            return .failure(id: 0, code: .protocolError, message: "malformed request line")
        }
        var response: Response?
        let done = DispatchSemaphore(value: 0)
        actuationQueue.async { [handler] in
            response = handler(request)
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
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
