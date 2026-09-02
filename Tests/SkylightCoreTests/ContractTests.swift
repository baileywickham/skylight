import XCTest
import SkylightCore

final class ContractTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Req: Decodable { let method: String; let params: JSONValue; let line: String }
        struct Resp: Decodable { let name: String; let decodes_to: String; let json: JSONValue }
        struct ValueCase: Decodable { let kind: String; let json: JSONValue }
        let requests: [Req]
        let responses: [Resp]
        let json_values: [ValueCase]
    }

    private func loadFixtures() throws -> Fixtures {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("contracts/fixtures.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    func testEveryRequestFixtureDecodesIntoItsInputType() throws {
        for req in try loadFixtures().requests {
            let request = try JSONDecoder().decode(Request.self, from: Data(req.line.utf8))
            XCTAssertEqual(request.method, req.method)
            switch req.method {
            case "capabilities": break // no params
            case "list_apps": _ = try request.decodeParams(ListAppsInput.self)
            case "list_windows": _ = try request.decodeParams(ListWindowsInput.self)
            case "get_app_state": _ = try request.decodeParams(GetAppStateInput.self)
            case "click": _ = try request.decodeParams(ClickInput.self)
            case "press_key": _ = try request.decodeParams(PressKeyInput.self)
            case "type_text": _ = try request.decodeParams(TypeTextInput.self)
            case "scroll": _ = try request.decodeParams(ScrollInput.self)
            case "set_value": _ = try request.decodeParams(SetValueInput.self)
            case "drag": _ = try request.decodeParams(DragInput.self)
            case "perform_secondary_action": _ = try request.decodeParams(PerformSecondaryActionInput.self)
            case "select_text": _ = try request.decodeParams(SelectTextInput.self)
            case "list_displays", "read_clipboard": break // no params
            case "screenshot": _ = try request.decodeParams(ScreenshotInput.self)
            case "zoom": _ = try request.decodeParams(ZoomInput.self)
            case "write_clipboard": _ = try request.decodeParams(WriteClipboardInput.self)
            case "bring_to_active_space": _ = try request.decodeParams(BringToActiveSpaceInput.self)
            default: XCTFail("unhandled method \(req.method)")
            }
        }
    }

    func testEveryResponseFixtureDecodesIntoItsResultType() throws {
        for resp in try loadFixtures().responses {
            let data = try JSONEncoder().encode(resp.json)
            switch resp.decodes_to {
            case "CapabilitiesResult": _ = try JSONDecoder().decode(CapabilitiesResult.self, from: data)
            case "ListAppsResult": _ = try JSONDecoder().decode(ListAppsResult.self, from: data)
            case "ListWindowsResult": _ = try JSONDecoder().decode(ListWindowsResult.self, from: data)
            case "AppState": _ = try JSONDecoder().decode(AppState.self, from: data)
            case "ActionResult": _ = try JSONDecoder().decode(ActionResult.self, from: data)
            case "ListDisplaysResult": _ = try JSONDecoder().decode(ListDisplaysResult.self, from: data)
            case "DisplayScreenshotResult": _ = try JSONDecoder().decode(DisplayScreenshotResult.self, from: data)
            case "ClipboardResult": _ = try JSONDecoder().decode(ClipboardResult.self, from: data)
            case "BringToActiveSpaceResult": _ = try JSONDecoder().decode(BringToActiveSpaceResult.self, from: data)
            default: XCTFail("unhandled result type \(resp.decodes_to)")
            }
        }
    }

    /// Task 2 review noted `.null`/`.number`/`.string`/`.array` lacked direct round-trip
    /// coverage (only `.bool`/`.object` were exercised via other tests). These fixtures
    /// close that gap: each JSONValue case is decoded from its fixture literal, checked
    /// against the expected case, then re-encoded and re-decoded to confirm a lossless
    /// round-trip.
    func testJSONValuePrimitiveCasesRoundTrip() throws {
        for item in try loadFixtures().json_values {
            switch (item.kind, item.json) {
            case ("null", .null): break
            case ("number", .number): break
            case ("string", .string): break
            case ("array", .array): break
            default: XCTFail("fixture kind \(item.kind) did not decode into the matching JSONValue case: \(item.json)")
            }
            let encoded = try JSONEncoder().encode(item.json)
            let roundTripped = try JSONDecoder().decode(JSONValue.self, from: encoded)
            XCTAssertEqual(roundTripped, item.json)
        }
    }
}
