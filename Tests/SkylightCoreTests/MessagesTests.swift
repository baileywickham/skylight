import XCTest
import SkylightCore

final class MessagesTests: XCTestCase {
    func testDecodeRequestLine() throws {
        let line = #"{"id":7,"method":"click","params":{"app":"Notes","element_index":12}}"#
        let req = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        XCTAssertEqual(req.id, 7)
        XCTAssertEqual(req.method, "click")
        let input = try req.decodeParams(ClickInput.self)
        XCTAssertEqual(input.app, "Notes")
        XCTAssertEqual(input.element_index, 12)
    }

    func testSuccessResponseRoundTrip() throws {
        let resp = try Response.success(id: 3, result: ActionResult(done: true))
        let data = try JSONEncoder().encode(resp)
        let back = try JSONDecoder().decode(Response.self, from: data)
        XCTAssertEqual(back.id, 3)
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.result, .object(["done": .bool(true)]))
        XCTAssertNil(back.error)
    }

    func testFailureResponse() throws {
        let resp = Response.failure(id: 9, code: .notImplemented, message: "select_text lands in milestone 2")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "not_implemented")
        XCTAssertEqual(resp.error?.message, "select_text lands in milestone 2")
    }

    func testErrorCodeSlugs() {
        XCTAssertEqual(SkyErrorCode.staleElementIndex.rawValue, "stale_element_index")
        XCTAssertEqual(SkyErrorCode.elementNotActionable.rawValue, "element_not_actionable")
        XCTAssertEqual(SkyErrorCode.permissionDenied.rawValue, "permission_denied")
    }
}
