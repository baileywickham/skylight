import Foundation
import SkylightCore

func doctor() {
    let status = Permissions.status()
    print("skylight doctor")
    print("  accessibility:    \(status.accessibility ? "granted" : "MISSING")")
    print("  screen recording: \(status.screen_recording ? "granted" : "MISSING (or lapsed — macOS re-prompts periodically)")")
    for line in Permissions.instructions(for: status) { print("  -> \(line)") }
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

    Background mode: start the DAEMON with SKYLIGHT_BACKGROUND=1 and actions run
    without stealing focus (no activation; synthetic events go per-pid via
    CGEventPostToPid). Reliable for element_index actions; best-effort for
    coordinate clicks / keyboard (menu shortcuts like Cmd+c need frontmost).
    """)
}

switch CommandLine.arguments.dropFirst().first {
case "doctor": doctor()
case "start": start()
case "usage": usage()
default:
    print("usage: skylight <start|doctor|usage>")
    exit(2)
}
