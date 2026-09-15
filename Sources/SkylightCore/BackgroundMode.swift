import Foundation

/// The daemon-wide default for whether an action runs in the background (no
/// activation, no raise, per-pid event delivery). A request's own `background`
/// field always wins; this only decides requests that leave it out.
public enum BackgroundMode: String, Codable, CaseIterable, Equatable {
    /// Background whenever this macOS build exposes the focus-without-raise
    /// symbols, foreground otherwise. Without those symbols background key
    /// input is best-effort (menu equivalents may not fire), so `auto` never
    /// silently trades reliability for not stealing focus. The built-in default.
    case auto
    /// Always background.
    case on
    /// Always foreground (activate + raise before each action).
    case off

    /// Lenient parse shared by settings.json and SKYLIGHT_BACKGROUND, so the
    /// env var's historical `1`/`true`/`yes` spellings keep meaning `on`.
    public init?(parsing raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto": self = .auto
        case "on", "1", "true", "yes": self = .on
        case "off", "0", "false", "no": self = .off
        default: return nil
        }
    }

    public func resolve(focusWithoutRaiseAvailable: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .auto: return focusWithoutRaiseAvailable
        }
    }
}

/// Where the effective `BackgroundMode` came from, for `skylight doctor` and
/// `skylight background`.
public enum BackgroundModeSource: String, Equatable {
    case settingsFile = "settings.json"
    case environment = "SKYLIGHT_BACKGROUND"
    case builtIn = "default"
}

/// Daemon settings persisted under the support dir. Only `background` today.
public struct DaemonSettings: Codable, Equatable {
    public var background: String?
    public init(background: String? = nil) { self.background = background }
}

/// Resolves the background default. Precedence: settings.json (what
/// `skylight background` writes) > SKYLIGHT_BACKGROUND > `.auto`. A missing,
/// malformed, or unrecognized value at one level falls through to the next
/// rather than failing. Reloaded on every call — like `Approvals` — so a mode
/// change applies to the next request without restarting the daemon.
public struct BackgroundSettings {
    public let fileURL: URL
    private let environment: [String: String]
    private let focusWithoutRaiseAvailable: () -> Bool

    public init(fileURL: URL = SkylightPaths.settingsFile,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                focusWithoutRaiseAvailable: @escaping () -> Bool = { SkyLightBridge.canFocusWithoutRaise }) {
        self.fileURL = fileURL
        self.environment = environment
        self.focusWithoutRaiseAvailable = focusWithoutRaiseAvailable
    }

    public func mode() -> (mode: BackgroundMode, source: BackgroundModeSource) {
        if let data = try? Data(contentsOf: fileURL),
           let settings = try? JSONDecoder().decode(DaemonSettings.self, from: data),
           let mode = settings.background.flatMap(BackgroundMode.init(parsing:)) {
            return (mode, .settingsFile)
        }
        if let mode = environment["SKYLIGHT_BACKGROUND"].flatMap(BackgroundMode.init(parsing:)) {
            return (mode, .environment)
        }
        return (.auto, .builtIn)
    }

    /// The effective default for a request that sets no `background` field.
    public func resolvedDefault() -> Bool {
        mode().mode.resolve(focusWithoutRaiseAvailable: focusWithoutRaiseAvailable())
    }

    /// Persists `mode`, keeping any other settings already in the file.
    public func save(_ mode: BackgroundMode) throws {
        var settings = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(DaemonSettings.self, from: $0) } ?? DaemonSettings()
        settings.background = mode.rawValue
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
