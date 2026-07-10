import XCTest
import SkylightCore

final class RouterTests: XCTestCase {
    func testRoutesRegisteredMethod() {
        let router = RequestRouter()
        router.register("ping") { req in
            try! Response.success(id: req.id, result: ["pong": true])
        }
        let resp = router.route(Request(id: 1, method: "ping", params: .object([:])))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.result, .object(["pong": .bool(true)]))
    }

    func testUnknownMethod() {
        let router = RequestRouter()
        let resp = router.route(Request(id: 2, method: "warp_drive", params: nil))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "unknown_method")
    }
}
