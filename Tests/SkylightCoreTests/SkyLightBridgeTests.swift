import XCTest
@testable import SkylightCore

final class SkyLightBridgeTests: XCTestCase {
    /// The probe must never trap, whatever the host macOS exposes — a missing
    /// symbol is a degraded capability, not a crash.
    func testCapabilityProbeIsSafeAndRepeatable() {
        let first = SkyLightBridge.capabilities()
        let second = SkyLightBridge.capabilities()
        XCTAssertEqual(first, second, "capabilities are cached symbol lookups; must be stable")
    }

    func testCapabilitiesRoundTripThroughJSON() throws {
        let caps = SkyLightCapabilities(focus_without_raise: true, trusted_events: false, space_management: true)
        let data = try JSONEncoder().encode(caps)
        XCTAssertEqual(try JSONDecoder().decode(SkyLightCapabilities.self, from: data), caps)
    }

    /// trusted_events stays false unless explicitly opted in, regardless of
    /// whether the symbol resolved — the signature is unverified (see
    /// SkyLightBridge).
    func testTrustedEventsAreOffWithoutOptIn() throws {
        guard !SkyLightBridge.trustedEventsEnabled else {
            throw XCTSkip("SKYLIGHT_TRUSTED_EVENTS is set in this environment")
        }
        XCTAssertFalse(SkyLightBridge.capabilities().trusted_events)
    }

    /// Spaces queries must never trap whatever this host exposes; an unknown
    /// window id yields nil/empty, not a crash.
    func testSpaceQueriesAreSafeOnUnknownWindow() {
        _ = SkyLightBridge.activeSpace()
        let spaces = SkyLightBridge.spaces(forWindow: 0)
        XCTAssertTrue(spaces == nil || spaces!.isEmpty)
        XCTAssertNil(SkyLightBridge.isOnActiveSpace(windowID: 0))
        XCTAssertEqual(SkyLightBridge.capabilities().space_management, SkyLightBridge.canManageSpaces)
    }

    func testPsnEqualityComparesBothHalves() {
        let a = ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 2)
        XCTAssertTrue(psnEquals(a, ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 2)))
        XCTAssertFalse(psnEquals(a, ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 3)))
        XCTAssertFalse(psnEquals(a, ProcessSerialNumber(highLongOfPSN: 9, lowLongOfPSN: 2)))
    }

    /// Not an assertion about the host: records posted to our own psn either
    /// work or are rejected, and both are fine. This pins that the call path
    /// survives a real invocation without trapping.
    func testPostingToOwnProcessDoesNotTrap() throws {
        guard let psn = SkyLightBridge.processSerialNumber(forPid: getpid()) else {
            throw XCTSkip("GetProcessForPID unavailable on this host")
        }
        _ = SkyLightBridge.post(record: EventRecord.activation(windowID: 0, activate: false), to: psn)
    }
}
