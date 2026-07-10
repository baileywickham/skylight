import Foundation

public struct ApprovalsConfig: Codable, Equatable {
    /// "allow_all" (default) or "allowlist".
    public var mode: String
    /// App names and/or bundle ids (case-insensitive); "*" allows everything.
    public var allow: [String]
    public init(mode: String, allow: [String]) {
        self.mode = mode
        self.allow = allow
    }
}

/// Per-app actuation gate, modeled on Sky's per-app approvals. Fails OPEN on a
/// missing or malformed file (allow_all): the gate is opt-in, and a corrupt
/// config must not brick every action for a personal tool. Reloaded on every
/// check so edits (or `skylight approve`) apply without a daemon restart.
public struct Approvals {
    public let fileURL: URL

    public init(fileURL: URL = SkylightPaths.approvalsFile) {
        self.fileURL = fileURL
    }

    public func load() -> ApprovalsConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(ApprovalsConfig.self, from: data) else {
            return ApprovalsConfig(mode: "allow_all", allow: [])
        }
        return cfg
    }

    /// Fails toward safety: allow-all only when `mode` is explicitly
    /// "allow_all" (case-insensitive). Any other decoded mode string —
    /// "allowlist", a typo like "Allowlist", or anything else — is treated
    /// as allowlist, so a mangled mode value can never silently fail open.
    public static func isAllowed(config: ApprovalsConfig, name: String?, bundleID: String?) -> Bool {
        guard config.mode.lowercased() == "allow_all" else {
            let allowed = Set(config.allow.map { $0.lowercased() })
            if allowed.contains("*") { return true }
            return [name, bundleID].compactMap { $0?.lowercased() }.contains { allowed.contains($0) }
        }
        return true
    }

    public func check(name: String?, bundleID: String?) throws {
        guard Approvals.isAllowed(config: load(), name: name, bundleID: bundleID) else {
            let label = name ?? bundleID ?? "app"
            throw SkyServiceError(code: .approvalRequired,
                message: "'\(label)' is not approved for actuation — run 'skylight approve \"\(label)\"' or edit \(fileURL.path)")
        }
    }
}
