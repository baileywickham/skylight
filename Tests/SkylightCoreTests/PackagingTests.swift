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

    func testLaunchAgentIsBundleRelative() throws {
        // Registered via SMAppService from inside the .app, so the program path
        // must be bundle-relative (BundleProgram), never an absolute path, and
        // nothing in it may depend on $HOME (launchd does not expand it).
        let agent = try plist("packaging/com.skylight.SkylightService.plist")
        XCTAssertEqual(agent["Label"] as? String, "com.skylight.SkylightService")
        XCTAssertEqual(agent["BundleProgram"] as? String, "Contents/MacOS/SkylightService")
        XCTAssertNil(agent["ProgramArguments"])
        XCTAssertNil(agent["StandardErrorPath"])
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        // The daemon redirects its own stderr to ~/Library/Logs/skylight when
        // launched this way (see SkylightService/main.swift).
        let envVars = agent["EnvironmentVariables"] as? [String: String]
        XCTAssertEqual(envVars?["SKYLIGHT_STDERR_TO_LOG"], "1")
    }

    func testShellScriptsParse() throws {
        for script in ["scripts/build.sh", "scripts/install-local.sh", "scripts/skylight-run", "release.sh"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", repoRoot.appendingPathComponent(script).path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(script) has a syntax error")
        }
    }
}
