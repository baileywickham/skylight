import XCTest
import SkylightCore

final class AuditLogTests: XCTestCase {
    func testRecordAppendsTabSeparatedLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skylight-logs-\(UUID())")
        let log = AuditLog(directory: dir)
        log.record(method: "click", target: "Notes[12]", outcome: "ok")
        log.record(method: "type_text", target: "Notes", outcome: "error:actuation_paused")
        let content = try String(contentsOf: dir.appendingPathComponent("actuation.log"), encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("\tclick\tNotes[12]\tok"))
        XCTAssertTrue(lines[1].hasSuffix("\ttype_text\tNotes\terror:actuation_paused"))
    }
}
