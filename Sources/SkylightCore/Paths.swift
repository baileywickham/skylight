import Foundation

public enum SkylightPaths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
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
    /// Per-app actuation allowlist; absent file = allow_all (opt-in gate).
    public static var approvalsFile: URL {
        supportDir.appendingPathComponent("approvals.json")
    }
}
