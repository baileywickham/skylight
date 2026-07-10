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

    // MARK: - layoutKeyCode (chords name CHARACTERS; events carry HARDWARE codes)
    //
    // On a non-QWERTY layout (e.g. Dvorak) posting the ANSI code for "c" types
    // "j", so Cmd+c fires an unbound shortcut and silently no-ops. Character
    // keys must be remapped through the active layout; positional keys must not.

    func testLayoutKeyCodeRemapsCharacterKeys() {
        // Dvorak places "c" on the ANSI "i" key (34) and "v" on ">"/"." (47).
        let dvorakish: [Character: CGKeyCode] = ["c": 34, "v": 47, "a": 0]
        XCTAssertEqual(layoutKeyCode(forAnsi: 8, layoutMap: dvorakish), 34)  // c
        XCTAssertEqual(layoutKeyCode(forAnsi: 9, layoutMap: dvorakish), 47)  // v
        XCTAssertEqual(layoutKeyCode(forAnsi: 0, layoutMap: dvorakish), 0)   // a (same key)
    }

    func testLayoutKeyCodePassesPositionalKeysThrough() {
        let bogus: [Character: CGKeyCode] = ["c": 99]
        XCTAssertEqual(layoutKeyCode(forAnsi: 36, layoutMap: bogus), 36)   // Return
        XCTAssertEqual(layoutKeyCode(forAnsi: 53, layoutMap: bogus), 53)   // Escape
        XCTAssertEqual(layoutKeyCode(forAnsi: 123, layoutMap: bogus), 123) // Left
        XCTAssertEqual(layoutKeyCode(forAnsi: 49, layoutMap: bogus), 49)   // Space
    }

    func testLayoutKeyCodeFallsBackWhenLayoutLacksCharacter() {
        XCTAssertEqual(layoutKeyCode(forAnsi: 8, layoutMap: [:]), 8)
    }

    func testCurrentKeyboardLayoutMapIsUsable() {
        // Layout-agnostic sanity: every Latin-capable layout types these.
        let map = currentKeyboardLayoutMap()
        try? XCTSkipIf(map.isEmpty, "no keyboard layout data available on this runner")
        XCTAssertNotNil(map["a"])
        XCTAssertEqual(map["1"], 18) // number row beats keypad (lowest code wins)
    }

    // MARK: - keyEventSequence (real held modifiers around the main key)
    //
    // NSMenu key equivalents (Cmd+c, Cmd+v, …) only fire when the modifier is
    // delivered as its own held key event, not just as flags on the main key.

    func testPlainKeySequenceHasNoModifierEvents() throws {
        let steps = keyEventSequence(for: try parseKeyChord("Return"))
        XCTAssertEqual(steps, [
            KeyEventStep(keyCode: 36, keyDown: true, flags: []),
            KeyEventStep(keyCode: 36, keyDown: false, flags: []),
        ])
    }

    func testCommandCSequenceHoldsCommandAroundKey() throws {
        let steps = keyEventSequence(for: try parseKeyChord("Cmd+c"))
        XCTAssertEqual(steps, [
            KeyEventStep(keyCode: 55, keyDown: true, flags: [.maskCommand]), // Cmd down
            KeyEventStep(keyCode: 8, keyDown: true, flags: [.maskCommand]),  // c down
            KeyEventStep(keyCode: 8, keyDown: false, flags: [.maskCommand]), // c up
            KeyEventStep(keyCode: 55, keyDown: false, flags: []),            // Cmd up
        ])
    }

    func testMultiModifierSequenceAccumulatesAndReleasesInReverse() throws {
        let steps = keyEventSequence(for: try parseKeyChord("Ctrl+Shift+t"))
        XCTAssertEqual(steps, [
            KeyEventStep(keyCode: 59, keyDown: true, flags: [.maskControl]),
            KeyEventStep(keyCode: 56, keyDown: true, flags: [.maskControl, .maskShift]),
            KeyEventStep(keyCode: 17, keyDown: true, flags: [.maskControl, .maskShift]),
            KeyEventStep(keyCode: 17, keyDown: false, flags: [.maskControl, .maskShift]),
            KeyEventStep(keyCode: 56, keyDown: false, flags: [.maskControl]),
            KeyEventStep(keyCode: 59, keyDown: false, flags: []),
        ])
    }

    func testAllFourModifiersUseDistinctKeyCodesAndFullyRelease() throws {
        let steps = keyEventSequence(for: try parseKeyChord("Cmd+Ctrl+Option+Shift+a"))
        XCTAssertEqual(steps.count, 10) // 4 downs + key down/up + 4 ups
        let modifierDowns = steps.prefix(4).map(\.keyCode)
        XCTAssertEqual(Set(modifierDowns), [55, 56, 58, 59])
        // Main key carries the full combined flags.
        XCTAssertEqual(steps[4].keyCode, 0)
        XCTAssertEqual(steps[4].flags, [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        // Releases mirror the downs in reverse order, ending with no flags held.
        XCTAssertEqual(steps.suffix(4).map(\.keyCode), modifierDowns.reversed())
        XCTAssertEqual(steps.last?.flags, [])
    }
}
