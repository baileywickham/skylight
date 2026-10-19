import Foundation

public enum SkylightPaths {
    /// `SKYLIGHT_SUPPORT_DIR` relocates the socket, approvals, settings and
    /// shots together, so a dev daemon can run beside the installed one
    /// without touching its socket or config.
    public static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["SKYLIGHT_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/skylight")
    }
    public static var socketPath: String {
        supportDir.appendingPathComponent("ipc/computeruse.sock").path
    }
    public static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/skylight")
    }
    public static var pauseFile: URL {
        supportDir.appendingPathComponent("SKYLIGHT_PAUSE")
    }
    /// Default screenshot output directory. Must be ABSOLUTE: under launchd /
    /// `open -a` the daemon's cwd is `/`, so a cwd-relative default would try
    /// to create `/.skylight/shots` and fail every capture with EACCES.
    public static var shotsDir: URL {
        supportDir.appendingPathComponent("shots")
    }
    /// Daemon settings (`skylight background`); absent file = built-in defaults.
    public static var settingsFile: URL {
        supportDir.appendingPathComponent("settings.json")
    }
    /// Per-app actuation allowlist; absent file = allow_all (opt-in gate).
    public static var approvalsFile: URL {
        supportDir.appendingPathComponent("approvals.json")
    }
}
