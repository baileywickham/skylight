import AppKit
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
// SKYLIGHT_BACKGROUND=1: run actions without stealing focus — activation is
// skipped for every action and synthetic events are posted per-pid
// (CGEventPostToPid) instead of to the session tap. Default OFF preserves the
// activation-first behavior exactly. See Actuation/Activation.swift for the
// best-effort caveats on keyboard/coordinate input to non-frontmost apps.
let background = ["1", "true", "yes"].contains((env["SKYLIGHT_BACKGROUND"] ?? "").lowercased())
let screenshotter = Screenshotter(shotsDir: shotsDir)
let actuator = Actuator(registry: registry, capture: axCapture,
                        postActionSleepMs: postActionSleepMs, background: background)

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
    // AX-only fallback: a failed screenshot (Screen Recording ungranted or
    // lapsed — macOS 15 re-prompts periodically — or a transient SCK error)
    // degrades the response instead of failing it; the model still gets the
    // tree, so the diff baseline below still commits (I1's invariant is
    // "never advance past a tree the model never saw" — it saw this one).
    var shot: ScreenshotResult?
    var shotError: String?
    do {
        shot = try awaitResult {
            try await screenshotter.capture(window: captured.window,
                                            includeDataURL: input.include_data_url ?? false)
        }
    } catch let error as SkyServiceError {
        shotError = "\(error.code.rawValue): \(error.message)"
    }
    axCapture.commitBaseline(captured, forPid: app.processIdentifier)
    auditLog.record(method: "get_app_state", target: input.app,
                    outcome: shotError == nil ? "ok" : "ok-ax-only")
    return AppState(text: captured.text, screenshot: shot,
                    screenshot_error: shotError, diffed: captured.diffed)
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
    let mode = background ? " (background mode: actions will not steal focus)" : ""
    FileHandle.standardError.write(Data("SkylightService \(SkylightVersion.current) listening at \(SkylightPaths.socketPath)\(mode)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}

// Kill switch with cleanup: a plain signal-handler `exit(0)` would leave a
// stale socket file behind. SIG_IGN + a main-queue DispatchSource lets clean
// shutdown run normal code (stop the server, unlink the socket) safely.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    server.stop() // closes the listen fd and unlinks the socket
    exit(0)
}
sigterm.resume()

// The MAIN RUN LOOP must be pumped (dispatchMain() does not pump it):
// NSWorkspace.shared.runningApplications and NSRunningApplication properties
// (isActive, …) only refresh while the main run loop runs in a common mode.
// Without it, apps launched after daemon startup stay invisible to
// list_apps/get_app_state forever and is_frontmost never updates. A bare
// RunLoop.main.run() is NOT enough (verified live): the workspace update
// machinery only runs in a process with an NSApplication connection, so run as
// an activation-policy-.accessory NSApplication — no Dock icon, no UI, but a
// live NSWorkspace. IPC accept and all actuation stay on their own background
// threads / the single global serial actuation queue; only the run-loop pump
// lives here.
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
_ = NSWorkspace.shared.runningApplications // register update machinery on this loop
nsApp.run()
