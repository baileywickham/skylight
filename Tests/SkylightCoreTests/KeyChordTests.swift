import CoreGraphics
import XCTest
import SkylightCore

final class KeyChordTests: XCTestCase {
    func testSingleLetter() throws {
        let chord = try parseKeyChord("a")
        XCTAssertEqual(chord.keyCode, 0) // kVK_ANSI_A
        XCTAssertEqual(chord.flags, [])
    }

    func testCommandShiftLetter() throws {
        let chord = try parseKeyChord("Cmd+Shift+t")
        XCTAssertEqual(chord.keyCode, 17) // kVK_ANSI_T
        XCTAssertEqual(chord.flags, [.maskCommand, .maskShift])
    }

    func testModifierAliases() throws {
        XCTAssertEqual(try parseKeyChord("Control+c").flags, [.maskControl])
        XCTAssertEqual(try parseKeyChord("Ctrl+c").flags, [.maskControl])
        XCTAssertEqual(try parseKeyChord("Alt+c").flags, [.maskAlternate])
        XCTAssertEqual(try parseKeyChord("Option+c").flags, [.maskAlternate])
        XCTAssertEqual(try parseKeyChord("Super+c").flags, [.maskCommand])
        XCTAssertEqual(try parseKeyChord("Command+c").flags, [.maskCommand])
    }

    func testKeysymNames() throws {
        XCTAssertEqual(try parseKeyChord("Return").keyCode, 36)
        XCTAssertEqual(try parseKeyChord("Escape").keyCode, 53)
        XCTAssertEqual(try parseKeyChord("BackSpace").keyCode, 51)
        XCTAssertEqual(try parseKeyChord("Tab").keyCode, 48)
        XCTAssertEqual(try parseKeyChord("space").keyCode, 49)
        XCTAssertEqual(try parseKeyChord("Left").keyCode, 123)
        XCTAssertEqual(try parseKeyChord("Down").keyCode, 125)
        XCTAssertEqual(try parseKeyChord("F5").keyCode, 96)
    }

    func testCaseInsensitiveLookup() throws {
        XCTAssertEqual(try parseKeyChord("return").keyCode, 36)
        XCTAssertEqual(try parseKeyChord("SHIFT+A").keyCode, 0)
    }

    func testUnknownKeyThrowsInvalidParams() {
        XCTAssertThrowsError(try parseKeyChord("Cmd+Bogus")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .invalidParams)
        }
        XCTAssertThrowsError(try parseKeyChord("Cmd+")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .invalidParams)
        }
    }
}
