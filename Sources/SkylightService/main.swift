import Foundation
import SkylightCore

// A client that disconnects before reading its response must never kill the
// daemon: ignore SIGPIPE process-wide (writes then fail with EPIPE instead).
signal(SIGPIPE, SIG_IGN)

let router = RequestRouter()
let registry = AppRegistry()
let axCapture = AXCapture()
let auditLog = AuditLog()

let env = ProcessInfo.processInfo.environment
// Default to an absolute path the daemon can always write: launched via
// launchd/`open -a` its cwd is `/`, so a cwd-relative default would fail
// every screenshot with EACCES.
let shotsDir = env["SKYLIGHT_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
    ?? SkylightPaths.shotsDir
let postActionSleepMs = env["SKYLIGHT_POST_ACTION_SLEEP_MS"].flatMap(Int.init) ?? 100
let screenshotter = Screenshotter(shotsDir: shotsDir)
let actuator = Actuator(registry: registry, capture: axCapture, postActionSleepMs: postActionSleepMs)

/// Wraps a throwing handler: SkyServiceError → structured error response,
/// anything else → capture_failed with the description.
func handle<I: Decodable, O: Encodable>(
    _ method: String,
    _ input: I.Type,
    _ body: @escaping (I) throws -> O
) -> (Request) -> Response {
    { req in
        do {
            let decoded = try req.decodeParams(I.self)
            return try Response.success(id: req.id, result: try body(decoded))
        } catch let error as SkyServiceError {
            return .failure(id: req.id, code: error.code, message: error.message)
        } catch {
            return .failure(id: req.id, code: .captureFailed, message: "\(method): \(error)")
        }
    }
}

/// Actuation variant: also writes the audit log line.
func actuation<I: Decodable>(
    _ method: String,
    _ input: I.Type,
    target: @escaping (I) -> String,
    _ body: @escaping (I) throws -> ActionResult
) -> (Request) -> Response {
    handle(method, I.self) { decoded in
        do {
            let result = try body(decoded)
            auditLog.record(method: method, target: target(decoded), outcome: "ok")
            return result
        } catch let error as SkyServiceError {
            auditLog.record(method: method, target: target(decoded), outcome: "error:\(error.code.rawValue)")
            throw error
        }
    }
}

struct EmptyParams: Decodable {}

// NOTE: brief's reference main.swift constructs `Response(id:ok:result:error:)`
// directly for ping/echo. `Response` (SkylightCore/Protocol/Messages.swift) has
// no public initializer, only `Response.success`/`Response.failure` factories,
// so a cross-module direct init would fail to compile. Kept the existing
// factory-based construction (byte-for-byte same wire behavior) instead.
router.register("ping") { req in
    (try? Response.success(
        id: req.id,
        result: JSONValue.object(["pong": .bool(true), "version": .string(SkylightVersion.current)])
    )) ?? .failure(id: req.id, code: .protocolError, message: "encoding ping result failed")
}
router.register("echo") { req in
    (try? Response.success(id: req.id, result: req.params ?? JSONValue.object([:])))
        ?? .failure(id: req.id, code: .protocolError, message: "encoding echo result failed")
}
router.register("list_apps", handle("list_apps", EmptyParams.self) { _ in registry.listApps() })
router.register("get_app_state", handle("get_app_state", GetAppStateInput.self) { input in
    let app = try registry.resolve(input.app)
    let captured = try axCapture.capture(app: app, disableDiff: input.disableDiff ?? false)
    let shot = try awaitResult {
        try await screenshotter.capture(window: captured.window,
                                        includeDataURL: input.include_data_url ?? false)
    }
    // Commit the diff baseline only now that the whole capture — screenshot
    // included — succeeded; a capture_failed/permission_denied screenshot must
    // not advance the baseline past a tree the model never saw.
    axCapture.commitBaseline(captured, forPid: app.processIdentifier)
    auditLog.record(method: "get_app_state", target: input.app, outcome: "ok")
    return AppState(text: captured.text, screenshot: shot, diffed: captured.diffed)
})
router.register("click", actuation("click", ClickInput.self,
    target: { "\($0.app)[\($0.element_index.map(String.init) ?? "@\($0.x ?? -1),\($0.y ?? -1)")]" },
    actuator.click))
router.register("press_key", actuation("press_key", PressKeyInput.self,
    target: { "\($0.app) keys=\($0.keys)" }, actuator.pressKey))
router.register("type_text", actuation("type_text", TypeTextInput.self,
    target: { "\($0.app) (\($0.text.count) chars)" }, actuator.typeText))
router.register("scroll", actuation("scroll", ScrollInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.direction) x\($0.pages)" }, actuator.scroll))
router.register("set_value", actuation("set_value", SetValueInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.setValue))
router.register("drag", actuation("drag", DragInput.self,
    target: { "\($0.app) (\($0.from_x),\($0.from_y))->(\($0.to_x),\($0.to_y))" }, actuator.drag))
router.register("perform_secondary_action", actuation("perform_secondary_action", PerformSecondaryActionInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.action)" }, actuator.performSecondaryAction))
router.register("select_text", actuation("select_text", SelectTextInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.selectText))

// Startup permission report: precise instructions if grants are missing.
let status = Permissions.status()
for line in Permissions.instructions(for: status) {
    FileHandle.standardError.write(Data("warning: \(line)\n".utf8))
}

let server = IPCServer(socketPath: SkylightPaths.socketPath, handler: router.route)
do {
    try server.start()
    FileHandle.standardError.write(Data("SkylightService \(SkylightVersion.current) listening at \(SkylightPaths.socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}

signal(SIGTERM) { _ in exit(0) } // kill switch
dispatchMain()
