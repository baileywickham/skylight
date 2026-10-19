import Foundation

/// How much an approved app may be driven. Ordered: each tier allows
/// everything the one below it does.
///
/// - read: captured and searched, never actuated (reads are not gated at all).
/// - click: plain left clicks, hovers, scrolls, text selection — nothing that
///   enters text or reaches a Paste: no typing, key presses, value writes,
///   right/modifier clicks, drags, context menus or menu items.
/// - full: everything.
public enum ApprovalTier: String, Codable, Comparable, CaseIterable {
    case read, click, full

    private var rank: Int {
        switch self {
        case .read: return 0
        case .click: return 1
        case .full: return 2
        }
    }

    public static func < (lhs: ApprovalTier, rhs: ApprovalTier) -> Bool { lhs.rank < rhs.rank }

    /// Case-insensitive, so a hand-edited "Full" does not fail the whole file
    /// to decode (which would drop every override back to the defaults).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let tier = ApprovalTier(rawValue: raw.lowercased()) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown tier '\(raw)' (read|click|full)"))
        }
        self = tier
    }
}

/// Apps that get the `click` tier unless the config names them: terminals,
/// editors and script runners, where typed text is a shell command or code.
/// Text on screen can carry injected instructions, and an agent that can type
/// into one of these can run them. Matched against bundle ids; a trailing "."
/// matches the whole vendor prefix.
public let defaultClickTierBundleIDs: [String] = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
    "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
    "com.panic.Nova", "com.jetbrains.", "com.google.android.studio",
    "com.apple.ScriptEditor2", "com.apple.Automator",
]

public struct ApprovalsConfig: Codable, Equatable {
    /// "allow_all" (default) or "allowlist".
    public var mode: String
    /// App names and/or bundle ids (case-insensitive); "*" allows everything.
    public var allow: [String]
    /// Per-app tier overrides, keyed by app name or bundle id
    /// (case-insensitive). An entry approves the app at that tier whatever the
    /// mode, and overrides `defaultClickTierBundleIDs`.
    public var tiers: [String: ApprovalTier]?
    public init(mode: String, allow: [String], tiers: [String: ApprovalTier]? = nil) {
        self.mode = mode
        self.allow = allow
        self.tiers = tiers
    }

    private enum CodingKeys: String, CodingKey { case mode, allow, tiers }

    /// Tiers decode entry by entry: an unknown tier name drops that one entry
    /// (with a warning) instead of failing the whole file — which would fall
    /// back to allow_all and switch off the allowlist and every restriction.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode)
        allow = try c.decode([String].self, forKey: .allow)
        guard let raw = try c.decodeIfPresent([String: String].self, forKey: .tiers) else {
            tiers = nil
            return
        }
        var parsed: [String: ApprovalTier] = [:]
        for (app, value) in raw {
            if let tier = ApprovalTier(rawValue: value.lowercased()) {
                parsed[app] = tier
            } else {
                FileHandle.standardError.write(Data(
                    "warning: approvals: ignoring tier '\(value)' for '\(app)' (use read, click or full)\n".utf8))
            }
        }
        tiers = parsed
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

    /// For writers: the config on disk, nil when there is no file, and an
    /// error when there is one that does not decode — rewriting it from the
    /// allow_all fallback would erase the user's allowlist.
    public func loadForEditing() throws -> ApprovalsConfig? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ApprovalsConfig.self, from: data)
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

    /// The tier an app gets with no override: `click` for the apps in
    /// `defaultClickTierBundleIDs`, `full` for everything else.
    public static func defaultTier(bundleID: String?) -> ApprovalTier {
        guard let id = bundleID?.lowercased() else { return .full }
        let restricted = defaultClickTierBundleIDs.contains { entry in
            let e = entry.lowercased()
            return e.hasSuffix(".") ? id.hasPrefix(e) : id == e
        }
        return restricted ? .click : .full
    }

    /// The tier `name`/`bundleID` may be driven at, or nil when it is not
    /// approved at all. An explicit `tiers` entry wins (bundle id over name);
    /// otherwise an allowed app gets its default tier.
    public static func tier(config: ApprovalsConfig, name: String?, bundleID: String?) -> ApprovalTier? {
        if let tiers = config.tiers, !tiers.isEmpty {
            let lowered = Dictionary(tiers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            for key in [bundleID, name].compactMap({ $0?.lowercased() }) {
                if let tier = lowered[key] { return tier }
            }
        }
        guard isAllowed(config: config, name: name, bundleID: bundleID) else { return nil }
        return defaultTier(bundleID: bundleID)
    }

    /// Throws approval_required unless the app is approved at `need` or above.
    /// `action` names what was refused, so the message says what to change.
    public func check(name: String?, bundleID: String?, need: ApprovalTier = .full, action: String = "actuation") throws {
        let label = name ?? bundleID ?? "app"
        guard let tier = Approvals.tier(config: load(), name: name, bundleID: bundleID) else {
            throw SkyServiceError(code: .approvalRequired,
                message: "'\(label)' is not approved for actuation — run 'skylight approve \"\(label)\"' or edit \(fileURL.path)")
        }
        guard tier >= need else {
            throw SkyServiceError(code: .approvalRequired,
                message: "'\(label)' is approved at tier \(tier.rawValue), and \(action) needs \(need.rawValue). "
                    + "Ask the user; they can run 'skylight tier \"\(label)\" \(need.rawValue)' to allow it.")
        }
    }
}
