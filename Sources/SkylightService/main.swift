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
        // only the resulting status matters. It also fails outright
        // (SMAppServiceErrorDomain 57) when run by the cask's postflight_steps,
        // inside Homebrew's sandboxed install-step child — retrying there does
        // not help. `skylight start`, which skylight-run calls whenever the
        // socket is down, registers again from a normal context.
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
// Background by default: actions skip activation and post synthetic events
// per-pid after focusWithoutRaise, so the user's frontmost app, window order,
// and cursor are left alone. A request's `background` field wins; otherwise
// settings.json (`skylight background on|off|auto`) > SKYLIGHT_BACKGROUND >
// `auto` (background wherever focus-without-raise resolved). Re-read per
// request, so switching modes needs no restart.
let backgroundSettings = BackgroundSettings()
let displayGeometry = DisplayGeometryStore()
let screenshotter = Screenshotter(shotsDir: shotsDir, displayGeometry: displayGeometry)
let actuator = Actuator(registry: registry, capture: axCapture,
                        postActionSleepMs: postActionSleepMs, background: backgroundSettings.resolvedDefault(),
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

/// Captures an app's tree (and, when asked, its screenshot) and commits it as
/// the diff baseline — get_app_state, and an action's `return_state`.
func captureAppState(_ input: GetAppStateInput, includeScreenshot: Bool = true) throws -> AppState {
    let app = try registry.resolve(input.app)
    let captured = try axCapture.capture(app: app, windowID: input.window_id,
                                         disableDiff: input.disableDiff ?? false,
                                         caps: TreeCaps.standard.overridden(maxDepth: input.max_depth,
                                                                            maxNodes: input.max_nodes),
                                         rootIndex: input.root_element_index)
    guard includeScreenshot else {
        axCapture.commitTreeBaseline(captured, forPid: app.processIdentifier)
        return AppState(text: captured.text, screenshot: nil, diffed: captured.diffed)
    }
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
                                  windowID: captured.windowID, diffed: captured.diffed, scope: captured.scope)
    }
    axCapture.commitBaseline(committed, forPid: app.processIdentifier)
    return AppState(text: captured.text, screenshot: shot,
                    screenshot_error: shotError, diffed: captured.diffed)
}

/// Screenshot size for an action's `return_screenshot`: the MCP server's
/// default, so the image and its click geometry match what get_app_state
/// would have produced there.
let returnScreenshotMaxDimension = env["SKYLIGHT_MCP_MAX_DIMENSION"].flatMap(Int.init) ?? 1568

/// Actuation variant: also writes the audit log line, and honors the
/// `return_state` every action accepts (see PostActionParams).
func actuation<I: Decodable>(
    _ method: String,
    _ input: I.Type,
    target: @escaping (I) -> String,
    _ body: @escaping (I) throws -> ActionResult
) -> (Request) -> Response {
    { req in
        handle(method, I.self) { decoded in
            // Strict: a malformed return_state ("true" as a string) is an
            // error, not a request that silently returns no state.
            let post = try req.decodeParams(PostActionParams.self)
            let wantsState = post.return_state == true || post.return_screenshot == true
            // Refused before acting: once the action has run, an error would
            // read as if it had not.
            if wantsState, post.app == nil {
                throw SkyServiceError(code: .invalidParams, message: "\(method): return_state needs app")
            }
            let result: ActionResult
            do {
                result = try body(decoded)
                auditLog.record(method: method, target: target(decoded), outcome: "ok")
            } catch let error as SkyServiceError {
                auditLog.record(method: method, target: target(decoded), outcome: "error:\(error.code.rawValue)")
                throw error
            }
            guard wantsState, let app = post.app else { return result }
            let withShot = post.return_screenshot == true
            do {
                let state = try captureAppState(
                    GetAppStateInput(app: app, include_data_url: withShot ? true : nil,
                                     max_dimension: withShot ? returnScreenshotMaxDimension : nil),
                    includeScreenshot: withShot)
                return ActionResult(done: result.done, state: state)
            } catch let error as SkyServiceError {
                return ActionResult(done: result.done, state_error: "\(error.code.rawValue): \(error.message)")
            } catch {
                return ActionResult(done: result.done, state_error: "capture_failed: \(error)")
            }
        }(req)
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
                       background_mode: backgroundSettings.mode().mode.rawValue,
                       background_default: actuator.effectiveBackground(nil),
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
    let state = try captureAppState(input)
    auditLog.record(method: "get_app_state", target: input.app,
                    outcome: state.screenshot_error == nil ? "ok" : "ok-ax-only")
    return state
})
router.register("find", handle("find", FindInput.self) { input in
    let query = ElementQuery(role: input.role, text: input.text)
    guard !query.isEmpty else {
        throw SkyServiceError(code: .invalidParams, message: "find needs role and/or text")
    }
    let app = try registry.resolve(input.app)
    let outcome = try axCapture.find(app: app, windowID: input.window_id, rootIndex: input.root_element_index,
                                     query: query,
                                     caps: TreeCaps.standard.overridden(maxDepth: input.max_depth,
                                                                        maxNodes: input.max_nodes),
                                     limit: findResultLimit(input.max_results))
    return FindResult(matches: outcome.matches, truncated: outcome.truncated)
})
router.register("wait_for", handle("wait_for", WaitForInput.self) { input in
    try waitFor(input, app: try registry.resolve(input.app), capture: axCapture)
})
router.register("click", actuation("click", ClickInput.self,
    target: {
        let space = $0.display_id.map { "display:\($0)" } ?? ""
        return "\($0.app ?? "<implicit>")[\($0.element_index.map(String.init) ?? "@\($0.x ?? -1),\($0.y ?? -1)\(space)")]"
    },
    actuator.click))
router.register("hover", actuation("hover", HoverInput.self,
    target: {
        let space = $0.display_id.map { "display:\($0)" } ?? ""
        return "\($0.app ?? "<implicit>")[\($0.element_index.map(String.init) ?? "@\($0.x ?? -1),\($0.y ?? -1)\(space)")]"
    },
    actuator.hover))
router.register("press_key", actuation("press_key", PressKeyInput.self,
    target: { "\($0.app ?? "<frontmost>") keys=\($0.keys)" }, actuator.pressKey))
router.register("type_text", actuation("type_text", TypeTextInput.self,
    target: { "\($0.app ?? "<frontmost>") (\($0.text.count) chars)" }, actuator.typeText))
router.register("scroll", actuation("scroll", ScrollInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.direction) x\($0.pages)" }, actuator.scroll))
router.register("set_value", actuation("set_value", SetValueInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.setValue))
router.register("drag", actuation("drag", DragInput.self,
    target: { input in
        func end(_ index: Int?, _ x: Double?, _ y: Double?) -> String {
            index.map { "[\($0)]" } ?? "(\(x ?? -1),\(y ?? -1))"
        }
        return "\(input.app ?? "<implicit>") \(end(input.from_element_index, input.from_x, input.from_y))->"
            + "\(end(input.to_element_index, input.to_x, input.to_y))\(input.display_id.map { " display:\($0)" } ?? "")"
    },
    actuator.drag))
router.register("perform_secondary_action", actuation("perform_secondary_action", PerformSecondaryActionInput.self,
    target: { "\($0.app)[\($0.element_index)] \($0.action)" }, actuator.performSecondaryAction))
router.register("select_text", actuation("select_text", SelectTextInput.self,
    target: { "\($0.app)[\($0.element_index)]" }, actuator.selectText))
router.register("menu_select", actuation("menu_select", MenuSelectInput.self,
    target: { "\($0.app) \($0.path.joined(separator: " > "))" }, actuator.menuSelect))
router.register("open_app", handle("open_app", OpenAppInput.self) { input in
    do {
        let result = try actuator.openApp(input)
        auditLog.record(method: "open_app", target: "\(input.app)\(input.url.map { " url=\($0)" } ?? "")",
                        outcome: result.launched ? "launched" : "running")
        return result
    } catch let error as SkyServiceError {
        auditLog.record(method: "open_app", target: input.app, outcome: "error:\(error.code.rawValue)")
        throw error
    }
})

// Batch: several steps in one request, run in order inside one scheduling
// slot (see classifyRequest). Each step goes through the router exactly like
// a request of its own — same validation, approvals, pause file and audit
// line — so a batch can do nothing its steps could not do one at a time.
router.register("batch", handle("batch", BatchInput.self) { input in
    guard !input.steps.isEmpty, input.steps.count <= RequestClassifier.maxBatchSteps else {
        throw SkyServiceError(code: .invalidParams,
                              message: "batch needs 1...\(RequestClassifier.maxBatchSteps) steps (got \(input.steps.count))")
    }
    // Every step is checked before any runs, so a typo in step 5 does not
    // leave steps 1–4 done.
    if let bad = input.steps.first(where: { !RequestClassifier.batchableMethods.contains($0.method) }) {
        throw SkyServiceError(code: .invalidParams, message: "batch cannot run '\(bad.method)'")
    }
    let stopOnError = input.stop_on_error ?? true
    let deadline = Date().addingTimeInterval(RequestClassifier.batchBudgetSeconds)
    var results: [BatchStepResult] = []
    var stoppedReason: String?
    for (i, step) in input.steps.enumerated() {
        let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
        guard remainingMs > 0 else {
            stoppedReason = "time budget (\(Int(RequestClassifier.batchBudgetSeconds))s) used up before step \(i + 1); "
                + "steps \(i + 1)–\(input.steps.count) were not run"
            break
        }
        var params = step.params
        // A wait inside the batch may only use what the batch has left.
        if step.method == "wait_for", case .object(var fields) = params ?? .object([:]) {
            let asked = fields["timeout_ms"].flatMap { if case .number(let n) = $0 { return Int(n) } else { return nil } }
            fields["timeout_ms"] = .number(Double(min(waitTimeoutMs(asked), remainingMs)))
            params = .object(fields)
        }
        let response = router.route(Request(id: i, method: step.method, params: params))
        results.append(BatchStepResult(method: step.method, ok: response.ok,
                                       result: response.result, error: response.error))
        if !response.ok && stopOnError { break }
    }
    return BatchResult(results: results,
                       completed: results.count == input.steps.count && results.allSatisfy(\.ok),
                       stopped_reason: stoppedReason)
})

// Displays: whole-screen capture (the pixel-based computer-use path), a
// native-resolution zoom for small text, and the display list that names them.
router.register("list_displays", handle("list_displays", EmptyParams.self) { _ in listDisplays() })
router.register("screenshot", handle("screenshot", ScreenshotInput.self) { input in
    let result = try awaitResult { try await screenshotter.captureDisplay(input) }
    auditLog.record(method: "screenshot", target: "display:\(result.display_id)", outcome: "ok")
    return result
})
router.register("zoom", handle("zoom", ZoomInput.self) { input in
    // With `app`, the region is pixels of that app's latest get_app_state
    // image, so the crop must come from the SAME window that capture targeted
    // — the geometry it was computed against is the only thing that makes the
    // coordinates mean anything.
    guard let appIdentifier = input.app else {
        return try awaitResult { try await screenshotter.zoom(input) }
    }
    let app = try registry.resolve(appIdentifier)
    guard let geometry = axCapture.latestGeometry(forPid: app.processIdentifier) else {
        throw SkyServiceError(code: .invalidParams,
                              message: "no prior capture for '\(appIdentifier)' — zoom coordinates are get_app_state pixels; call get_app_state first")
    }
    let wantedID = input.window_id ?? axCapture.latestWindowID(forPid: app.processIdentifier)
    let window: AXUIElement
    if let wantedID, let listing = try axCapture.windowListings(of: app).first(where: { $0.info.window_id == wantedID }) {
        window = listing.element
    } else if input.window_id != nil {
        throw SkyServiceError(code: .invalidParams,
                              message: "window_id \(input.window_id!) not found for '\(appIdentifier)' — call list_windows for current ids")
    } else {
        window = try axCapture.focusedWindow(of: app)
    }
    return try awaitResult {
        try await screenshotter.zoomWindow(window: window, windowID: wantedID, geometry: geometry, input: input)
    }
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
    if request.method == "batch" {
        guard let input = try? request.decodeParams(BatchInput.self) else { return .exclusive }
        return RequestClassifier.classifyBatch(input.steps.map { step in
            step.method == "batch" ? .exclusive
                : classifyRequest(Request(id: request.id, method: step.method, params: step.params))
        })
    }
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
    let (mode, source) = backgroundSettings.mode()
    let effective = backgroundSettings.resolvedDefault() ? "background" : "foreground"
    FileHandle.standardError.write(Data("SkylightService \(SkylightVersion.current) listening at \(SkylightPaths.socketPath) (actions default to \(effective): background_mode=\(mode.rawValue) from \(source.rawValue))\n".utf8))
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
