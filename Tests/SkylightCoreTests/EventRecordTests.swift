import CoreGraphics
import XCTest
@testable import SkylightCore

/// Pins every magic offset in the window-server event records. These bytes are
/// undocumented: a live Mac gives no error when they are wrong, the record just
/// silently does nothing. So the offsets are asserted here rather than trusted.
final class EventRecordTests: XCTestCase {
    private let windowID: CGWindowID = 0x11223344

    /// Bytes expected to be non-zero, so "everything else is zero" can be
    /// asserted without listing 248 indices.
    private func assertZeroOutside(_ bytes: [UInt8], allowed: Set<Int>,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for (i, byte) in bytes.enumerated() where !allowed.contains(i) {
            XCTAssertEqual(byte, 0, "byte 0x\(String(i, radix: 16)) should be zero", file: file, line: line)
        }
    }

    func testRecordsAreExactlyOneStructureLong() {
        XCTAssertEqual(EventRecord.size, 0xf8)
        XCTAssertEqual(EventRecord.activation(windowID: windowID, activate: true).count, 0xf8)
        for record in EventRecord.keyWindow(windowID: windowID) {
            XCTAssertEqual(record.count, 0xf8)
        }
    }

    func testWindowIDIsLittleEndianAtOffset0x3c() {
        let bytes = EventRecord.activation(windowID: 0x11223344, activate: true)
        XCTAssertEqual(Array(bytes[0x3c..<0x40]), [0x44, 0x33, 0x22, 0x11])
    }

    func testActivateRecordSetsKindAndFlagAndFill() {
        let bytes = EventRecord.activation(windowID: windowID, activate: true)
        XCTAssertEqual(bytes[0x04], 0xf8, "magic")
        XCTAssertEqual(bytes[0x08], 0x0d, "activation record kind")
        XCTAssertEqual(bytes[0x8a], 1, "1 = activate")
        XCTAssertEqual(Array(bytes[0x20..<0x30]), [UInt8](repeating: 0xFF, count: 0x10))
        assertZeroOutside(bytes, allowed: Set([0x04, 0x08, 0x8a] + Array(0x20..<0x30) + Array(0x3c..<0x40)))
    }

    /// The deactivate record deliberately has NO 0xFF fill — it is posted to the
    /// outgoing front process, and yabai's working sequence leaves it zeroed.
    func testDeactivateRecordSetsFlagTwoAndNoFill() {
        let bytes = EventRecord.activation(windowID: windowID, activate: false)
        XCTAssertEqual(bytes[0x08], 0x0d)
        XCTAssertEqual(bytes[0x8a], 2, "2 = deactivate")
        XCTAssertEqual(Array(bytes[0x20..<0x30]), [UInt8](repeating: 0, count: 0x10))
        assertZeroOutside(bytes, allowed: Set([0x04, 0x08, 0x8a] + Array(0x3c..<0x40)))
    }

    func testKeyWindowIsAnOrderedPairOfKindOneThenTwo() {
        let records = EventRecord.keyWindow(windowID: windowID)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0][0x08], 0x01)
        XCTAssertEqual(records[1][0x08], 0x02)
    }

    func testKeyWindowRecordsCarryTagAndFill() {
        for record in EventRecord.keyWindow(windowID: windowID) {
            XCTAssertEqual(record[0x04], 0xf8, "magic")
            XCTAssertEqual(record[0x3a], 0x10, "key-window tag")
            XCTAssertEqual(Array(record[0x20..<0x30]), [UInt8](repeating: 0xFF, count: 0x10))
            XCTAssertEqual(Array(record[0x3c..<0x40]), [0x44, 0x33, 0x22, 0x11])
            assertZeroOutside(record, allowed: Set([0x04, 0x08, 0x3a] + Array(0x20..<0x30) + Array(0x3c..<0x40)))
        }
    }
}
