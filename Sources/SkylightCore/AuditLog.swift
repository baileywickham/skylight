import Foundation

/// Append-only actuation log (method + resolved target + result) for
/// auditability, per the spec's kill-switch/audit requirements.
public final class AuditLog {
    private let fileURL: URL
    private let iso8601 = ISO8601DateFormatter()

    public init(directory: URL = SkylightPaths.logsDir) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("actuation.log")
    }

    public func record(method: String, target: String, outcome: String) {
        let line = "\(iso8601.string(from: Date()))\t\(method)\t\(target)\t\(outcome)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
