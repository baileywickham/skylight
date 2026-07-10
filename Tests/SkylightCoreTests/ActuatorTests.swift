import XCTest
import SkylightCore

final class ActuatorTests: XCTestCase {
    private func makeActuator(paused: Bool = false) throws -> Actuator {
        let pauseFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKYLIGHT_PAUSE-\(UUID())")
        if paused {
            FileManager.default.createFile(atPath: pauseFile.path, contents: nil)
        }
        return Actuator(registry: AppRegistry(), capture: AXCapture(),
                        postActionSleepMs: 0, pauseFile: pauseFile)
    }

    private func assertThrowsCode(_ code: SkyErrorCode, _ body: @autoclosure () throws -> ActionResult,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, code, file: file, line: line)
        }
    }

    func testPauseSentinelHaltsAllActuation() throws {
        let actuator = try makeActuator(paused: true)
        assertThrowsCode(.actuationPaused, try actuator.click(ClickInput(app: "Finder", element_index: 0)))
        assertThrowsCode(.actuationPaused, try actuator.typeText(TypeTextInput(app: "Finder", text: "x")))
        assertThrowsCode(.actuationPaused, try actuator.pressKey(PressKeyInput(app: "Finder", keys: "Return")))
    }

    func testUnknownAppIsAppNotFound() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.appNotFound, try actuator.click(ClickInput(app: "Definitely Not An App 9000", element_index: 0)))
    }

    func testUnknownElementIndexIsStale() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.staleElementIndex, try actuator.setValue(SetValueInput(app: "Finder", element_index: 777, value: "x")))
    }

    func testClickNeedsIndexOrCoordinates() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder")))
    }

    func testCoordinateClickWithoutPriorCaptureIsInvalid() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder", x: 10, y: 10)))
    }

    func testBadMouseButtonAndDirectionAreInvalidParams() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder", x: 1, y: 1, mouse_button: "chartreuse")))
        assertThrowsCode(.invalidParams, try actuator.scroll(ScrollInput(app: "Finder", element_index: 777, direction: "sideways", pages: 1)))
    }

    func testSelectTextIsNotImplementedInMilestone1() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.notImplemented, try actuator.selectText(SelectTextInput(
            app: "Finder", element_index: 0, text: "hello", selection_type: "select")))
    }
}
