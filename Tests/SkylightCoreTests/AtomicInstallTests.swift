import XCTest
@testable import SkylightCore

final class AtomicInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skylight-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a minimal bundle-shaped directory whose marker file identifies it.
    private func makeBundle(_ name: String, marker: String) throws -> URL {
        let bundle = root.appendingPathComponent(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try marker.write(to: bundle.appendingPathComponent("Contents/Info.plist"),
                         atomically: true, encoding: .utf8)
        try marker.write(to: macos.appendingPathComponent("SkylightService"),
                         atomically: true, encoding: .utf8)
        return bundle
    }

    private func marker(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)
    }

    func testInstallsWhenDestinationIsAbsent() throws {
        let source = try makeBundle("staged.app", marker: "v2")
        let destination = root.appendingPathComponent("Installed.app")

        try AtomicInstall.install(source: source, destination: destination)

        XCTAssertEqual(try marker(of: destination), "v2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "source is moved, not copied")
    }

    func testReplacesExistingBundleContents() throws {
        let destination = root.appendingPathComponent("Installed.app")
        let old = try makeBundle("old.app", marker: "v1")
        try FileManager.default.moveItem(at: old, to: destination)
        let source = try makeBundle("staged.app", marker: "v2")

        try AtomicInstall.install(source: source, destination: destination)

        XCTAssertEqual(try marker(of: destination), "v2")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Contents/MacOS/SkylightService"),
                                  encoding: .utf8), "v2", "nested payload replaced too")
    }

    /// The property that matters for TCC: the destination path is occupied by a
    /// complete bundle at every instant, so macOS never sees the app disappear.
    func testDestinationIsNeverAbsentDuringReplacement() throws {
        let destination = root.appendingPathComponent("Installed.app")
        let old = try makeBundle("old.app", marker: "v1")
        try FileManager.default.moveItem(at: old, to: destination)
        let source = try makeBundle("staged.app", marker: "v2")

        let stop = DispatchSemaphore(value: 0)
        var sawMissing = false
        var sawPartial = false
        let watcher = Thread {
            let fm = FileManager.default
            while stop.wait(timeout: .now()) == .timedOut {
                if !fm.fileExists(atPath: destination.path) { sawMissing = true }
                else if !fm.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path) {
                    sawPartial = true
                }
            }
        }
        watcher.start()
        // Give the watcher a moment to actually start sampling before the swap.
        usleep(20_000)

        try AtomicInstall.install(source: source, destination: destination)

        stop.signal()
        usleep(20_000)
        XCTAssertFalse(sawMissing, "destination vanished mid-install — this is what drops TCC grants")
        XCTAssertFalse(sawPartial, "destination was observed half-populated")
        XCTAssertEqual(try marker(of: destination), "v2")
    }

    func testRejectsMissingSource() throws {
        let destination = root.appendingPathComponent("Installed.app")
        XCTAssertThrowsError(
            try AtomicInstall.install(source: root.appendingPathComponent("nope.app"),
                                      destination: destination)
        ) { error in
            guard case AtomicInstall.Failure.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }
    }

    func testRejectsFileAsSource() throws {
        let file = root.appendingPathComponent("notabundle")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try AtomicInstall.install(source: file, destination: root.appendingPathComponent("Installed.app"))
        ) { error in
            guard case AtomicInstall.Failure.notADirectory = error else {
                return XCTFail("expected notADirectory, got \(error)")
            }
        }
    }

    func testSameVolumeDetection() throws {
        XCTAssertTrue(AtomicInstall.sameVolume(root, root.appendingPathComponent("child")))
    }

    /// A failed install must leave the previous bundle intact and usable —
    /// a broken upgrade should never take the working daemon with it.
    func testFailedInstallLeavesExistingBundleIntact() throws {
        let destination = root.appendingPathComponent("Installed.app")
        let old = try makeBundle("old.app", marker: "v1")
        try FileManager.default.moveItem(at: old, to: destination)

        XCTAssertThrowsError(
            try AtomicInstall.install(source: root.appendingPathComponent("missing.app"),
                                      destination: destination))
        XCTAssertEqual(try marker(of: destination), "v1", "existing install survived a failed upgrade")
    }
}
