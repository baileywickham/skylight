import AppKit
import Foundation
import SkylightCore
import ServiceManagement

// `SkylightService --register` / `--unregister` / `--status`: manage the bundled LaunchAgent
// via SMAppService. This lives in the daemon (the bundle's CFBundleExecutable)
// rather than the `skylight` CLI because smd only honours registration from the
// bundle's main executable: registering from a helper binary "succeeds" but
// launchd then refuses to spawn the agent (EX_CONFIG) and unregister is denied.
// The CLI's `skylight register` execs this.
if let flag = CommandLine.arguments.dropFirst().first, ["--register", "--unregister", "--status"].contains(flag) {
    let service = SMAppService.agent(plistName: "com.skylight.SkylightService.plist")
    do {
        if flag == "--register" { try service.register() }
        if flag == "--unregister" { try service.unregister() }
    } catch {
        // register() throws on an already-enabled agent on some releases;
        // only the resulting status matters.
        if flag == "--unregister" || service.status != .enabled {
            FileHandle.standardError.write(Data("\(flag) failed: \(error)\n".utf8))
            exit(1)
        }
    }
    switch service.status {
    case .enabled: print("enabled")
    case .requiresApproval: print("requiresApproval")
    case .notRegistered: print("notRegistered")
    case .notFound: print("notFound")
    @unknown default: print("unknown")
    }
    exit(0)
}


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
let displayGeometry = DisplayGeometryStore()
let screenshotter = Screenshotter(shotsDir: shotsDir, displayGeometry: displayGeometry)
let actuator = Actuator(registry: registry, capture: axCapture,
                        postActionSleepMs: postActionSleepMs, background: background,
                        approvals: Approvals(), displayGeometry: displayGeometry)

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
router.register("capabilities", handle("capabilities", EmptyParams.self) { _ in
    CapabilitiesResult(version: SkylightVersion.current,
                       permissions: Permissions.status(),
                       skylight: SkyLightBridge.capabilities(),
                       background_default: background,
                       parallel_actuation: true)
})
router.register("list_apps", handle("list_apps", ListAppsInput.self) { input in
    registry.listApps(includeMenuBarApps: input.include_menu_bar_apps ?? false)
})
router.register("list_windows", handle("list_windows", ListWindowsInput.self) { input in
    let app = try registry.resolve(input.app)
    return ListWindowsResult(windows: try axCapture.windowListings(of: app).map(\.info))
})
router.register("get_app_state", handle("get_app_state", GetAppStateInput.self) { input in
    let app = try registry.resolve(input.app)
    let captured = try axCapture.capture(app: app, windowID: input.window_id,
                                         disableDiff: input.disableDiff ?? false)
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
                                            includeDataURL: input.include_data_url ?? false,
                                            maxDimension: input.max_dimension)
        }
    } catch let error as SkyServiceError {
        shotError = "\(error.code.rawValue): \(error.message)"
    } catch {
        // SCK/Cocoa errors are not SkyServiceError — normalize so a transient
        // ScreenCaptureKit failure also degrades to AX-only instead of failing.
        shotError = "capture_failed: \(error)"
    }
    // The click geometry must describe the image the model got: a
    // max_dimension downscale changes pixels-per-point, so commit the scale
    // the screenshot actually came back at (window origin is unchanged).
    var committed = captured
    if let scale = shot?.scale, scale != captured.geometry.scale {
        committed = CaptureResult(text: captured.text, lines: captured.lines, window: captured.window,
                                  geometry: CaptureGeometry(windowOriginX: captured.geometry.windowOriginX,
                                                            windowOriginY: captured.geometry.windowOriginY,
                                                            scale: scale),
                                  windowID: captured.windowID, diffed: captured.diffed)
    }
    axCapture.commitBaseline(committed, forPid: app.processIdentifier)
    auditLog.record(method: "get_app_state", target: input.app,
                    outcome: shotError == nil ? "ok" : "ok-ax-only")
    return AppState(text: captured.text, screenshot: shot,
                    screenshot_error: shotError, diffed: captured.diffed)
})
router.register("click", actuation("click", ClickInput.self,
    target: {
        let space = $0.display_id.map { "display:\($0)" } ?? ""
        return "\($0.app ?? "<implicit>")[\($0.element_index.map(String.init) ?? "@\($0.x ?? -1),\($0.y ?? -1)\(space)")]"
    },
    actuator.click))
router.register("press_key", actuation("press_key", PressKeyInput.self,
    target: { "\($0.app ?? "<frontmost>") keys=\($0.keys)" }, actuator.pressKey))
router.register("type_text", actuation("type_text", TypeTextInput.self,
    target: { "\($0.app ?? "<frontmost>") (\($0.text.count) chars)" }, actuator.typeText))
router.register("scroll", actuation("scroll", ScrollInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.direction) x\($0.pages)" }, actuator.scroll))
router.register("set_value", actuation("set_value", SetValueInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.setValue))
router.register("drag", actuation("drag", DragInput.self,
    target: { "\($0.app ?? "<implicit>") (\($0.from_x),\($0.from_y))->(\($0.to_x),\($0.to_y))\($0.display_id.map { " display:\($0)" } ?? "")" },
    actuator.drag))
router.register("perform_secondary_action", actuation("perform_secondary_action", PerformSecondaryActionInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.action)" }, actuator.performSecondaryAction))
router.register("select_text", actuation("select_text", SelectTextInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.selectText))

// Displays: whole-screen capture (the pixel-based computer-use path), a
// native-resolution zoom for small text, and the display list that names them.
router.register("list_displays", handle("list_displays", EmptyParams.self) { _ in listDisplays() })
router.register("screenshot", handle("screenshot", ScreenshotInput.self) { input in
    let result = try awaitResult { try await screenshotter.captureDisplay(input) }
    auditLog.record(method: "screenshot", target: "display:\(result.display_id)", outcome: "ok")
    return result
})
router.register("zoom", handle("zoom", ZoomInput.self) { input in
    try awaitResult { try await screenshotter.zoom(input) }
})

// Clipboard: not app-scoped, so not approval-gated; the write is audited.
router.register("read_clipboard", handle("read_clipboard", EmptyParams.self) { _ in Clipboard.read() })
router.register("write_clipboard", handle("write_clipboard", WriteClipboardInput.self) { input in
    if FileManager.default.fileExists(atPath: SkylightPaths.pauseFile.path) {
        throw SkyServiceError(code: .actuationPaused,
                              message: "actuation paused by \(SkylightPaths.pauseFile.path); remove the file to resume")
    }
    let result = Clipboard.write(text: input.text)
    auditLog.record(method: "write_clipboard", target: "(\(input.text.count) chars)", outcome: result.done ? "ok" : "error")
    return result
})

// Spaces: move a window onto the active Space without switching to its own.
router.register("bring_to_active_space", handle("bring_to_active_space", BringToActiveSpaceInput.self) { input in
    do {
        let result = try actuator.bringToActiveSpace(input)
        auditLog.record(method: "bring_to_active_space", target: "\(input.app)[\(result.window_id)]",
                        outcome: result.moved ? "moved" : (result.on_active_space ? "already" : "failed"))
        return result
    } catch let error as SkyServiceError {
        auditLog.record(method: "bring_to_active_space", target: input.app, outcome: "error:\(error.code.rawValue)")
        throw error
    }
})

// Under launchd there is no terminal and the bundled LaunchAgent plist cannot
// name a $HOME-relative StandardErrorPath, so the agent sets
// SKYLIGHT_STDERR_TO_LOG=1 and the daemon points its own stderr at the log.
if ProcessInfo.processInfo.environment["SKYLIGHT_STDERR_TO_LOG"] == "1" {
    let logURL = SkylightPaths.logsDir.appendingPathComponent("service.log")
    try? FileManager.default.createDirectory(at: SkylightPaths.logsDir, withIntermediateDirectories: true)
    let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 { dup2(fd, STDERR_FILENO); close(fd) }
}

// Startup permission report: precise instructions if grants are missing.
// Ask for Screen Recording FIRST when it is missing: the preflight the rest of
// the daemon uses never prompts, so without this the app never appears in the
// Screen & System Audio Recording list and the instruction below is impossible
// to follow. Re-checked afterwards so the report reflects a grant just given.
if !Permissions.status().screen_recording {
    Permissions.requestScreenRecording()
}
let status = Permissions.status()
for line in Permissions.instructions(for: status) {
    FileHandle.standardError.write(Data("warning: \(line)\n".utf8))
}

/// The subset of any request's params needed to schedule it. Decoded
/// leniently — every field is optional — because this runs for EVERY method,
/// including ones that name no app. Never used to drive an action.
struct SchedulingParams: Decodable {
    let app: String?
    let background: Bool?
}

/// Picks the scheduling key for a request: background work is keyed per app so
/// different apps proceed in parallel; foreground work is exclusive. The app
/// identifier is resolved to a pid HERE so that "Notes" and "com.apple.Notes"
/// cannot be handed two separate slots for the same app.
func classifyRequest(_ request: Request) -> RequestClass {
    let params = try? request.decodeParams(SchedulingParams.self)
    let appKey = params?.app
        .flatMap { try? registry.resolve($0) }
        .map { "pid:\($0.processIdentifier)" }
    return RequestClassifier.classify(method: request.method, appKey: appKey,
                                      background: actuator.effectiveBackground(params?.background))
}

let server = IPCServer(socketPath: SkylightPaths.socketPath,
                       classify: classifyRequest, handler: router.route)
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
