import XCTest
import SkylightCore

final class BackgroundModeTests: XCTestCase {
    private func tempSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("skylight-settings-\(UUID().uuidString)/settings.json")
    }

    private func settings(file: URL, env: [String: String] = [:], capable: Bool = true) -> BackgroundSettings {
        BackgroundSettings(fileURL: file, environment: env, focusWithoutRaiseAvailable: { capable })
    }

    func testParsingAcceptsModeNamesAndLegacyEnvSpellings() {
        XCTAssertEqual(BackgroundMode(parsing: "auto"), .auto)
        for raw in ["on", "ON", "1", "true", "yes", " on\n"] { XCTAssertEqual(BackgroundMode(parsing: raw), .on, raw) }
        for raw in ["off", "0", "false", "No"] { XCTAssertEqual(BackgroundMode(parsing: raw), .off, raw) }
        XCTAssertNil(BackgroundMode(parsing: ""))
        XCTAssertNil(BackgroundMode(parsing: "sometimes"))
    }

    func testAutoFollowsFocusWithoutRaiseAvailability() {
        XCTAssertTrue(BackgroundMode.auto.resolve(focusWithoutRaiseAvailable: true))
        XCTAssertFalse(BackgroundMode.auto.resolve(focusWithoutRaiseAvailable: false),
                       "auto must not pick best-effort background input on a build without the symbols")
        XCTAssertTrue(BackgroundMode.on.resolve(focusWithoutRaiseAvailable: false))
        XCTAssertFalse(BackgroundMode.off.resolve(focusWithoutRaiseAvailable: true))
    }

    func testBuiltInDefaultIsAutoAndBackgroundWhenCapable() {
        let s = settings(file: tempSettingsURL())
        XCTAssertEqual(s.mode().mode, .auto)
        XCTAssertEqual(s.mode().source, .builtIn)
        XCTAssertTrue(s.resolvedDefault())
        XCTAssertFalse(settings(file: tempSettingsURL(), capable: false).resolvedDefault())
    }

    func testEnvironmentBeatsBuiltInAndUnrecognizedEnvFallsThrough() {
        let off = settings(file: tempSettingsURL(), env: ["SKYLIGHT_BACKGROUND": "0"])
        XCTAssertEqual(off.mode().mode, .off)
        XCTAssertEqual(off.mode().source, .environment)
        XCTAssertFalse(off.resolvedDefault())

        let junk = settings(file: tempSettingsURL(), env: ["SKYLIGHT_BACKGROUND": "maybe"])
        XCTAssertEqual(junk.mode().source, .builtIn)
    }

    func testSettingsFileBeatsEnvironmentAndAppliesWithoutReconstruction() throws {
        let url = tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = settings(file: url, env: ["SKYLIGHT_BACKGROUND": "1"])
        XCTAssertTrue(s.resolvedDefault())

        try s.save(.off)
        XCTAssertEqual(s.mode().mode, .off, "re-read on every call: no daemon restart needed")
        XCTAssertEqual(s.mode().source, .settingsFile)
        XCTAssertFalse(s.resolvedDefault())

        try s.save(.on)
        XCTAssertEqual(try JSONDecoder().decode(DaemonSettings.self, from: Data(contentsOf: url)).background, "on")
    }

    func testMalformedSettingsFileFallsThroughToEnvironment() throws {
        let url = tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let s = settings(file: url, env: ["SKYLIGHT_BACKGROUND": "off"])
        XCTAssertEqual(s.mode().mode, .off)
        XCTAssertEqual(s.mode().source, .environment)
        XCTAssertNoThrow(try s.save(.on), "save overwrites a corrupt file instead of failing")
        XCTAssertEqual(s.mode().source, .settingsFile)
    }

    func testActuatorReResolvesDefaultPerRequest() {
        var configured = false
        let actuator = Actuator(registry: AppRegistry(), capture: AXCapture(), background: configured)
        XCTAssertFalse(actuator.effectiveBackground(nil))
        configured = true
        XCTAssertTrue(actuator.effectiveBackground(nil), "default is evaluated per request, not captured at init")
        XCTAssertFalse(actuator.effectiveBackground(false), "per-request override still wins")
    }
}
