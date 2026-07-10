import XCTest

final class PackagingTests: XCTestCase {
    private var repoRoot: URL {
        // Tests run from the package directory.
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func plist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relative))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }

    func testInfoPlistDeclaresBackgroundAgentIdentity() throws {
        let info = try plist("packaging/Info.plist")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.skylight.SkylightService")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "SkylightService")
    }

    func testLaunchAgentRunsTheBundledBinary() throws {
        let agent = try plist("packaging/com.skylight.SkylightService.plist")
        XCTAssertEqual(agent["Label"] as? String, "com.skylight.SkylightService")
        let args = agent["ProgramArguments"] as? [String]
        XCTAssertEqual(args?.first, "__HOME__/Applications/SkylightService.app/Contents/MacOS/SkylightService")
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        // C1: launchd starts the daemon with cwd `/`, so the shots dir must be
        // pinned to an absolute, writable location via the environment.
        let envVars = agent["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(envVars?["SKYLIGHT_SHOTS_DIR"],
                       "__HOME__/Library/Application Support/skylight/shots")
    }

    func testShellScriptsParse() throws {
        for script in ["scripts/package-app.sh", "scripts/install-launchagent.sh"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", repoRoot.appendingPathComponent(script).path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(script) has a syntax error")
        }
    }
}
