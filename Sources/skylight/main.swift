import Foundation
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
    let live = Permissions.socketIsLive(at: SkylightPaths.socketPath)
    print("  socket:           \(live ? "live" : "not listening") at \(SkylightPaths.socketPath)")
    if !live { print("  -> run 'skylight start'") }
    print("  note: grants shown here are for THIS process; the daemon's own doctor state")
    print("        is authoritative once SkylightService.app is installed and running.")
}

func start() {
    if Permissions.socketIsLive(at: SkylightPaths.socketPath) {
        print("SkylightService already running (socket live).")
        return
    }
    // Never exec the daemon as a terminal child: TCC would attribute the
    // permission checks to the terminal. Prefer the LaunchAgent, fall back to open -a.
    let label = "com.skylight.SkylightService"
    let agent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = FileManager.default.fileExists(atPath: agent.path)
        ? ["kickstart", "gui/\(getuid())/\(label)"]
        : []
    if task.arguments!.isEmpty {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "SkylightService"]
    }
    try? task.run()
    task.waitUntilExit()
    for _ in 0..<20 {
        if Permissions.socketIsLive(at: SkylightPaths.socketPath) {
            print("SkylightService started; socket live at \(SkylightPaths.socketPath)")
            return
        }
        usleep(250_000)
    }
    print("SkylightService did not come up. Install it first:")
    print("  scripts/package-app.sh && scripts/install-launchagent.sh")
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

    Background mode: pass background: true on any action to act without stealing
    focus (reliable for element_index actions; best-effort for coordinate clicks
    and keyboard — menu shortcuts like Cmd+c need frontmost). Or start the daemon
    with SKYLIGHT_BACKGROUND=1 to make that the default.

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

/// `skylight install-app <staged.app> <destination.app>` — used by
/// install-launchagent.sh. Kept out of `usage` because it is an installer
/// implementation detail, not something to run by hand.
func installApp() {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 2 else {
        print("usage: skylight install-app <staged-bundle> <destination-bundle>")
        exit(2)
    }
    do {
        try AtomicInstall.install(source: URL(fileURLWithPath: args[0]),
                                  destination: URL(fileURLWithPath: args[1]))
        print("installed \(args[1])")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "install-app": installApp()
case "doctor": doctor()
case "start": start()
case "usage": usage()
case "approvals": showApprovals()
case "approve":
    guard let name = CommandLine.arguments.dropFirst(2).first else {
        print("usage: skylight approve <app-name-or-bundle-id>")
        exit(2)
    }
    approve(name)
case "allow-all": allowAll()
default:
    print("usage: skylight <start|doctor|usage|approvals|approve <app>|allow-all>")
    exit(2)
}
