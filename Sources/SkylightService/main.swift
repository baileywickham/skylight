import Foundation
import SkylightCore

// A client that disconnects before reading its response must never kill the
// daemon: ignore SIGPIPE process-wide (writes then fail with EPIPE instead).
signal(SIGPIPE, SIG_IGN)

let router = RequestRouter()
router.register("ping") { req in
    try! Response.success(
        id: req.id,
        result: JSONValue.object(["pong": .bool(true), "version": .string(SkylightVersion.current)])
    )
}
router.register("echo") { req in
    try! Response.success(id: req.id, result: req.params ?? JSONValue.object([:]))
}
let registry = AppRegistry()
router.register("list_apps") { req in
    (try? Response.success(id: req.id, result: registry.listApps()))
        ?? .failure(id: req.id, code: .protocolError, message: "encoding list_apps result failed")
}

let shotsDir = ProcessInfo.processInfo.environment["SKYLIGHT_SHOTS_DIR"]
    .map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".skylight/shots")
let axCapture = AXCapture()
let screenshotter = Screenshotter(shotsDir: shotsDir)

router.register("get_app_state") { req in
    do {
        let input = try req.decodeParams(GetAppStateInput.self)
        let app = try registry.resolve(input.app)
        let captured = try axCapture.capture(app: app, disableDiff: input.disableDiff ?? false)
        let shot = try awaitResult {
            try await screenshotter.capture(window: captured.window,
                                            includeDataURL: input.include_data_url ?? false)
        }
        let state = AppState(text: captured.text, screenshot: shot, diffed: captured.diffed)
        return try Response.success(id: req.id, result: state)
    } catch let error as SkyServiceError {
        return .failure(id: req.id, code: error.code, message: error.message)
    } catch {
        return .failure(id: req.id, code: .captureFailed, message: "\(error)")
    }
}

let server = IPCServer(socketPath: SkylightPaths.socketPath, handler: router.route)
do {
    try server.start()
    FileHandle.standardError.write(Data("SkylightService \(SkylightVersion.current) listening at \(SkylightPaths.socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}

signal(SIGTERM) { _ in exit(0) }
dispatchMain()
