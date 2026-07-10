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
}
