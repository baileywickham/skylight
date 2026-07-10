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

    func testLeftRightModifierAliases() throws {
        // Reference API examples: Control_L+a and Super_L+d must resolve, not throw.
        let controlL = try parseKeyChord("Control_L+a")
        XCTAssertEqual(controlL.keyCode, 0) // kVK_ANSI_A
        XCTAssertEqual(controlL.flags, [.maskControl])

        let superL = try parseKeyChord("Super_L+d")
        XCTAssertEqual(superL.keyCode, 2) // kVK_ANSI_D
        XCTAssertEqual(superL.flags, [.maskCommand])

        let shiftR = try parseKeyChord("Shift_R+x")
        XCTAssertEqual(shiftR.keyCode, 7) // kVK_ANSI_X
        XCTAssertEqual(shiftR.flags, [.maskShift])
    }

    func testMetaMapsToOption() throws {
        let meta = try parseKeyChord("Meta+a")
        XCTAssertEqual(meta.flags, [.maskAlternate])
        XCTAssertNotEqual(meta.flags, [.maskCommand])

        let option = try parseKeyChord("Option+a")
        let alt = try parseKeyChord("Alt+a")
        XCTAssertEqual(meta.flags, option.flags)
        XCTAssertEqual(meta.flags, alt.flags)
    }

    func testWhitespaceToleranceAroundModifiers() throws {
        let spaced = try parseKeyChord("Cmd + Shift + t")
        let tight = try parseKeyChord("Cmd+Shift+t")
        XCTAssertEqual(spaced.keyCode, tight.keyCode)
        XCTAssertEqual(spaced.flags, tight.flags)
        XCTAssertEqual(spaced.keyCode, 17) // kVK_ANSI_T
        XCTAssertEqual(spaced.flags, [.maskCommand, .maskShift])
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
