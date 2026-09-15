import Foundation
import ServiceManagement
import SkylightCore

func doctor() {
    let status = Permissions.status()
    print("skylight doctor")
    print("  accessibility:    \(status.accessibility ? "granted" : "MISSING")")
    print("  screen recording: \(status.screen_recording ? "granted" : "MISSING (or lapsed — macOS re-prompts periodically)")")
    for line in Permissions.instructions(for: status) { print("  -> \(line)") }
    let caps = SkyLightBridge.capabilities()
    print("  focus w/o raise:  \(caps.focus_without_raise ? "available" : "UNAVAILABLE")")
    if !caps.focus_without_raise {
        print("  -> background actions still work, but menu shortcuts (Cmd+c) may not fire")
        print("     in a non-frontmost app: this macOS build no longer exposes the SkyLight")
        print("     symbols skylight uses to activate an app without raising it.")
    }
    print("  trusted events:   \(caps.trusted_events ? "enabled" : "off (experimental; SKYLIGHT_TRUSTED_EVENTS=1)")")
    print("  spaces:           \(caps.space_management ? "available" : "UNAVAILABLE (bring_to_active_space disabled)")")
    let background = cliBackgroundSettings()
    print("  background:       \(background.mode().mode.rawValue) → actions default to \(background.resolvedDefault() ? "background" : "foreground") ('skylight background on|off|auto')")
    print("  bundle:           \(insideBundle ? bundleURL.path : "not inside SkylightService.app (dev build)")")
    let live = Permissions.socketIsLive(at: SkylightPaths.socketPath)
    print("  socket:           \(live ? "live" : "not listening") at \(SkylightPaths.socketPath)")
    if !live { print("  -> run 'skylight start'") }
    print("  note: grants shown here are for THIS process; the daemon's own doctor state")
    print("        is authoritative once SkylightService.app is installed and running.")
}

/// The CLI reads the settings file only: SKYLIGHT_BACKGROUND in THIS shell is
/// not the daemon's environment, so reporting it here would mislead.
func cliBackgroundSettings() -> BackgroundSettings {
    BackgroundSettings(environment: [:])
}

/// `skylight background [on|off|auto]` — show or set the daemon's default for
/// actions that don't pass `background`. The daemon re-reads the file on every
/// request, so a change applies immediately.
func background(_ arg: String?) {
    let settings = cliBackgroundSettings()
    if let arg {
        guard let mode = BackgroundMode(parsing: arg) else {
            print("usage: skylight background [on|off|auto]")
            exit(2)
        }
        do { try settings.save(mode) } catch {
            print("error: cannot write \(settings.fileURL.path): \(error)")
            exit(1)
        }
    }
    let (mode, source) = settings.mode()
    let effective = settings.resolvedDefault()
    print("background mode: \(mode.rawValue)\(source == .settingsFile ? "" : " (default)")")
    print("  actions default to \(effective ? "background: no activation, no raise, cursor untouched" : "foreground: activate + raise the app first")")
    if mode == .auto && !effective {
        print("  -> focus-without-raise is unavailable on this macOS build, so auto stays foreground;")
        print("     'skylight background on' forces background anyway (menu shortcuts may not fire)")
    }
    if source != .settingsFile {
        print("  (SKYLIGHT_BACKGROUND in the daemon's environment, if set, overrides this default)")
    }
    if arg != nil { print("  saved to \(settings.fileURL.path); applies to the next request, no restart needed") }
}

let agentLabel = "com.skylight.SkylightService"
let agentPlist = "\(agentLabel).plist"

/// The bundled LaunchAgent lives at Contents/Library/LaunchAgents/ and is
/// managed through the daemon binary (`SkylightService --register`): smd only
/// honours SMAppService calls from the bundle's main executable, so this CLI
/// (a second Mach-O in Contents/MacOS) delegates rather than calling
/// SMAppService itself.
///
/// Derived from the resolved executable path, not `Bundle.main.bundleURL`: the
/// cask links this CLI into brew's bin, and for a symlinked executable
/// Bundle.main takes the symlink's directory (/opt/homebrew/bin) as the bundle,
/// so `skylight register`/`start` from PATH thought they were outside the .app.
var bundleURL: URL {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        return Bundle.main.bundleURL
    }
    // <bundle>.app/Contents/MacOS/skylight
    return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
var daemonURL: URL { bundleURL.appendingPathComponent("Contents/MacOS/SkylightService") }

var insideBundle: Bool {
    bundleURL.pathExtension == "app"
        && FileManager.default.fileExists(atPath: bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlist)").path)
}

/// Runs `SkylightService --register|--unregister` and returns its status word.
func agentControl(_ flag: String) -> String {
    let task = Process()
    task.executableURL = daemonURL
    task.arguments = [flag]
    let out = Pipe()
    task.standardOutput = out
    do { try task.run() } catch {
        print("error: cannot run \(daemonURL.path): \(error)")
        exit(1)
    }
    task.waitUntilExit()
    let word = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if task.terminationStatus != 0 {
        print("error: \(flag) failed (\(word.isEmpty ? "see above" : word))")
        exit(1)
    }
    return word
}

func agentStatus() -> String { agentControl("--status") }

func describe(_ status: String) -> String {
    switch status {
    case "enabled": return "enabled"
    case "requiresApproval": return "requires approval (System Settings > General > Login Items)"
    case "notRegistered": return "not registered"
    case "notFound": return "not found (LaunchAgent plist missing from the bundle)"
    default: return status
    }
}

/// `skylight register` — register the bundled LaunchAgent with launchd
/// (idempotent) and start the daemon. This is the whole install step: the
/// cask's postflight runs it, and it is safe to rerun any time.
func register() {
    guard insideBundle else {
        print("skylight register must run from inside SkylightService.app")
        print("  (e.g. /Applications/SkylightService.app/Contents/MacOS/skylight register)")
        exit(1)
    }
    let status = agentControl("--register")
    print("LaunchAgent \(agentLabel): \(describe(status))")
    if status == "requiresApproval" {
        print("  -> approve it under System Settings > General > Login Items, then run 'skylight start'")
        SMAppService.openSystemSettingsLoginItems()
        exit(1)
    }
    start()
}

/// `skylight unregister` — stop the daemon and remove the LaunchAgent.
func unregister() {
    guard insideBundle else {
        print("skylight unregister must run from inside SkylightService.app")
        exit(1)
    }
    _ = agentControl("--unregister")
    print("LaunchAgent \(agentLabel) unregistered")
}

/// `launchctl kickstart` for the agent; false when launchd doesn't have it.
@discardableResult
func kickstart(quiet: Bool) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
    if quiet { task.standardError = FileHandle.nullDevice }
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

func start() {
    if Permissions.socketIsLive(at: SkylightPaths.socketPath) {
        print("SkylightService already running (socket live).")
        return
    }
    // Never exec the daemon as a terminal child: TCC would attribute the
    // permission checks to the terminal. launchd owns it; we only kick it.
    if insideBundle, agentStatus() != "enabled" {
        print("LaunchAgent \(agentLabel): \(describe(agentStatus()))")
        print("  -> run 'skylight register'")
        exit(1)
    }
    if !kickstart(quiet: true) && insideBundle {
        // SMAppService can report the agent enabled while launchd has no such
        // service — what a cask upgrade leaves behind if its postflight
        // register failed. Registering again loads it.
        print("LaunchAgent \(agentLabel) is not loaded in launchd; re-registering...")
        _ = agentControl("--register")
        kickstart(quiet: false)
    }
    for _ in 0..<20 {
        if Permissions.socketIsLive(at: SkylightPaths.socketPath) {
            print("SkylightService started; socket live at \(SkylightPaths.socketPath)")
            return
        }
        usleep(250_000)
    }
    print("SkylightService did not come up. Check ~/Library/Logs/skylight/service.log,")
    print("or (re)install it: brew install --cask skylight  (dev: scripts/install-local.sh)")
    exit(1)
}

func usage() {
    print("""
    Skylight — computer use for Claude Code. From a TypeScript script run with tsx:

        import { sky } from "@skylight/sky";   // ts/src/index.ts
        const state = await sky.get_app_state({ app: "Notes" });
        // state.text = indexed AX tree; state.screenshot.url = file:// PNG — view it with Read
        await sky.click({ app: "Notes", element_index: 12 });
        await sky.type_text({ app: "Notes", text: "hello" });

    Type declarations: ts/sky.d.ts. Config via SKYLIGHT_CONFIG_PATH
    ({ socket_path, post_action_sleep_ms, shots_dir }).

    Pixel path: sky.screenshot() (whole display), sky.zoom({x,y,width,height}),
    sky.click({x, y, display_id}); clipboard: read_clipboard/write_clipboard;
    Spaces: bring_to_active_space({app, window_id}).

    MCP: `skylight-run --mcp` serves all of this as tools over stdio
    (claude mcp add --scope user skylight -- skylight-run --mcp).

    Background: actions run without activating or raising the app by default,
    so you keep working while the agent drives other apps (and actions on
    different apps run in parallel). 'skylight background on|off|auto' sets the
    default (auto = background wherever this macOS build supports
    focus-without-raise); pass background: false on a call to bring the app
    to the front for it.

    Approvals: 'skylight approve <app>' switches actuation to an allowlist
    ('skylight approvals' to inspect, 'skylight allow-all' to reset). Unlisted
    apps fail with approval_required.
    """)
}

func showApprovals() {
    let approvals = Approvals()
    let cfg = approvals.load()
    print("approvals file: \(approvals.fileURL.path)")
    print("mode: \(cfg.mode)")
    for entry in cfg.allow { print("  allow: \(entry)") }
    if cfg.mode != "allowlist" {
        print("  (allow_all: every app may be actuated; 'skylight approve <app>' to lock down)")
    }
}

func approve(_ name: String) {
    let approvals = Approvals()
    var cfg = approvals.load()
    cfg.mode = "allowlist"
    if !cfg.allow.contains(where: { $0.lowercased() == name.lowercased() }) {
        cfg.allow.append(name)
    }
    writeApprovals(cfg, to: approvals.fileURL)
    print("approved '\(name)'; mode=allowlist (\(cfg.allow.count) app(s) allowed)")
}

func allowAll() {
    let approvals = Approvals()
    writeApprovals(ApprovalsConfig(mode: "allow_all", allow: []), to: approvals.fileURL)
    print("approvals reset: allow_all")
}

func writeApprovals(_ cfg: ApprovalsConfig, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cfg).write(to: url, options: .atomic)
    } catch {
        print("error: cannot write \(url.path): \(error)")
        exit(1)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "doctor": doctor()
case "start": start()
case "register": register()
case "unregister": unregister()
case "usage": usage()
case "approvals": showApprovals()
case "approve":
    guard let name = CommandLine.arguments.dropFirst(2).first else {
        print("usage: skylight approve <app-name-or-bundle-id>")
        exit(2)
    }
    approve(name)
case "allow-all": allowAll()
case "background": background(CommandLine.arguments.dropFirst(2).first)
default:
    print("usage: skylight <start|register|unregister|doctor|usage|approvals|approve <app>|allow-all|background [on|off|auto]>")
    exit(2)
}
