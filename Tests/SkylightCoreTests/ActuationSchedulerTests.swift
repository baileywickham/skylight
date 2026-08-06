import XCTest
@testable import SkylightCore

/// Concurrency tests use real threads. Each one is made deterministic by having
/// the first body block on a semaphore the test controls, so overlap (or the
/// absence of it) is observed rather than raced for.
final class ActuationSchedulerTests: XCTestCase {
    private func runInBackground(_ block: @escaping () -> Void) {
        Thread.detachNewThread(block)
    }

    /// The point of the whole feature: two agents driving different apps at the
    /// same time.
    func testDifferentKeysRunConcurrently() {
        let scheduler = ActuationScheduler()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondFinished = expectation(description: "second key ran while the first was held")

        runInBackground {
            scheduler.run(.keyed("Notes")) {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        runInBackground {
            scheduler.run(.keyed("Safari")) { secondFinished.fulfill() }
        }
        wait(for: [secondFinished], timeout: 2)
        releaseFirst.signal()
    }

    /// Two requests for one app must never interleave — same rule Codex
    /// enforces, for the same reason: shared per-app state and a single visual
    /// context.
    func testSameKeySerializes() {
        let scheduler = ActuationScheduler()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        runInBackground {
            scheduler.run(.keyed("Notes")) {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        runInBackground {
            scheduler.run(.keyed("Notes")) { _ = secondEntered.signal() }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.3), .timedOut,
                       "second request for the same app must wait")

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success,
                       "and proceed once the first releases")
    }

    /// Foreground actions activate apps and move the real cursor, so they must
    /// not overlap anything.
    func testExclusiveWaitsForKeyedWorkAndBlocksIt() {
        let scheduler = ActuationScheduler()
        let keyedEntered = DispatchSemaphore(value: 0)
        let releaseKeyed = DispatchSemaphore(value: 0)
        let exclusiveEntered = DispatchSemaphore(value: 0)

        runInBackground {
            scheduler.run(.keyed("Notes")) {
                keyedEntered.signal()
                releaseKeyed.wait()
            }
        }
        XCTAssertEqual(keyedEntered.wait(timeout: .now() + 2), .success)

        runInBackground {
            scheduler.run(.exclusive) { _ = exclusiveEntered.signal() }
        }
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 0.3), .timedOut,
                       "exclusive must wait for in-flight keyed work")

        releaseKeyed.signal()
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 2), .success)
    }

    /// A waiting exclusive request takes priority, so a stream of background
    /// work cannot starve a foreground one.
    func testWaitingExclusiveBlocksNewKeyedWork() {
        let scheduler = ActuationScheduler()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let exclusiveQueued = DispatchSemaphore(value: 0)
        let lateKeyedEntered = DispatchSemaphore(value: 0)

        runInBackground {
            scheduler.run(.keyed("Notes")) {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        runInBackground {
            exclusiveQueued.signal()
            scheduler.run(.exclusive) {}
        }
        XCTAssertEqual(exclusiveQueued.wait(timeout: .now() + 2), .success)
        usleep(100_000) // let the exclusive request register as waiting

        // A different key would normally be admitted immediately.
        runInBackground {
            scheduler.run(.keyed("Safari")) { _ = lateKeyedEntered.signal() }
        }
        XCTAssertEqual(lateKeyedEntered.wait(timeout: .now() + 0.3), .timedOut,
                       "new keyed work must yield to the queued exclusive request")

        releaseFirst.signal()
        XCTAssertEqual(lateKeyedEntered.wait(timeout: .now() + 2), .success)
    }

    /// A failed action must not wedge its app forever.
    func testThrowingBodyReleasesItsSlot() {
        struct Boom: Error {}
        let scheduler = ActuationScheduler()
        XCTAssertThrowsError(try scheduler.run(.keyed("Notes")) { throw Boom() })
        XCTAssertEqual(scheduler.activeKeyCount, 0)

        let ran = expectation(description: "same key is usable again")
        runInBackground { scheduler.run(.keyed("Notes")) { ran.fulfill() } }
        wait(for: [ran], timeout: 2)
    }

    func testManyConcurrentKeysAllComplete() {
        let scheduler = ActuationScheduler()
        let done = expectation(description: "all finished")
        done.expectedFulfillmentCount = 32
        let counter = NSLock()
        var peak = 0
        var live = 0

        for i in 0..<32 {
            runInBackground {
                scheduler.run(.keyed("app-\(i)")) {
                    counter.lock(); live += 1; peak = max(peak, live); counter.unlock()
                    usleep(20_000)
                    counter.lock(); live -= 1; counter.unlock()
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(peak, 1, "distinct keys should have overlapped")
        XCTAssertEqual(scheduler.activeKeyCount, 0)
    }
}
