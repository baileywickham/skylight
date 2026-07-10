import Carbon.HIToolbox
import CoreGraphics
import Foundation

public struct KeyChord: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }
}

private let modifierFlags: [String: CGEventFlags] = [
    "control": .maskControl, "ctrl": .maskControl,
    "control_l": .maskControl, "control_r": .maskControl,
    "alt": .maskAlternate, "option": .maskAlternate,
    "alt_l": .maskAlternate, "alt_r": .maskAlternate,
    "option_l": .maskAlternate, "option_r": .maskAlternate,
    "shift": .maskShift,
    "shift_l": .maskShift, "shift_r": .maskShift,
    "command": .maskCommand, "cmd": .maskCommand, "super": .maskCommand,
    "meta": .maskAlternate,
    "meta_l": .maskAlternate, "meta_r": .maskAlternate,
    "super_l": .maskCommand, "super_r": .maskCommand,
]

/// X-keysym-style names (lowercased) → macOS virtual key codes (ANSI layout).
private let keyCodes: [String: CGKeyCode] = {
    let map: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
        "equal": 24, "minus": 27, "bracketright": 30, "bracketleft": 33,
        "quote": 39, "apostrophe": 39, "semicolon": 41, "backslash": 42,
        "comma": 43, "slash": 44, "period": 47, "grave": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "backspace": 51, "delete": 117, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page_up": 116, "prior": 116, "page_down": 121, "next": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    return map
}()

/// One synthesized keyboard event: `keyCode` pressed/released with `flags` held.
public struct KeyEventStep: Equatable {
    public let keyCode: CGKeyCode
    public let keyDown: Bool
    public let flags: CGEventFlags
    public init(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.keyDown = keyDown
        self.flags = flags
    }
}

/// Modifier flag → the virtual key code of its (left-hand) physical key.
/// Order fixes the press order; releases happen in reverse.
private let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
    (.maskControl, 59),   // kVK_Control
    (.maskAlternate, 58), // kVK_Option
    (.maskShift, 56),     // kVK_Shift
    (.maskCommand, 55),   // kVK_Command
]

/// True for the virtual key codes of the modifier keys themselves. Their
/// synthesized events must be posted as `.flagsChanged` (what physical
/// modifiers produce), not `.keyDown`/`.keyUp`.
public func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
    modifierKeys.contains { $0.keyCode == keyCode }
}

/// Expands a chord into the event sequence a physical typist produces: each
/// modifier pressed as its OWN key event (flags accumulating), the main key
/// down+up with the combined flags, then the modifiers released in reverse.
///
/// A single keyDown carrying `.maskCommand` as mere flags is NOT equivalent:
/// NSMenu key equivalents (Cmd+c/Cmd+v/…) only fire when the modifiers arrive
/// as real held keys, so the flags-only form silently no-ops menu shortcuts.
public func keyEventSequence(for chord: KeyChord) -> [KeyEventStep] {
    var steps: [KeyEventStep] = []
    var held: CGEventFlags = []
    for (flag, keyCode) in modifierKeys where chord.flags.contains(flag) {
        held.insert(flag)
        steps.append(KeyEventStep(keyCode: keyCode, keyDown: true, flags: held))
    }
    steps.append(KeyEventStep(keyCode: chord.keyCode, keyDown: true, flags: chord.flags))
    steps.append(KeyEventStep(keyCode: chord.keyCode, keyDown: false, flags: chord.flags))
    for (flag, keyCode) in modifierKeys.reversed() where chord.flags.contains(flag) {
        held.remove(flag)
        steps.append(KeyEventStep(keyCode: keyCode, keyDown: false, flags: held))
    }
    return steps
}

/// ANSI-table key code → the character it names (character keys only; keys
/// like Return/arrows/F5 are positional and layout-independent). Inverse of
/// the character entries in `keyCodes`.
private let ansiKeyCodeToCharacter: [CGKeyCode: Character] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
    28: "8", 29: "0", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j",
    40: "k", 45: "n", 46: "m",
    24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
    43: ",", 44: "/", 47: ".", 50: "`",
]

/// Character → virtual key code under the CURRENT keyboard layout, built by
/// asking UCKeyTranslate what each hardware key produces unmodified. Lowest
/// key code wins (number row over keypad). Empty on failure.
public func currentKeyboardLayoutMap() -> [Character: CGKeyCode] {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return [:]
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
    var map: [Character: CGKeyCode] = [:]
    layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
        for keyCode in CGKeyCode(0)..<CGKeyCode(128) {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let err = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                                     UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                     &deadKeyState, chars.count, &length, &chars)
            if err == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) {
                let character = Character(scalar)
                if map[character] == nil { map[character] = keyCode }
            }
        }
    }
    return map
}

/// Adjusts an ANSI-table key code to the active keyboard layout. Chord names
/// identify CHARACTERS ("Cmd+c" means copy), but CGEvents carry HARDWARE key
/// codes: on a non-QWERTY layout (e.g. Dvorak, where the ANSI "c" key types
/// "j") posting the ANSI code fires the wrong — usually unbound — shortcut,
/// which silently no-ops. Verified live: this, not the modifier synthesis,
/// made Cmd+c a no-op while Cmd+a (same position in both layouts) worked.
/// Positional keys (Return, arrows, …) and characters the layout cannot type
/// pass through unchanged. `layoutMap` is injectable for tests.
public func layoutKeyCode(forAnsi keyCode: CGKeyCode,
                          layoutMap: [Character: CGKeyCode]? = nil) -> CGKeyCode {
    guard let character = ansiKeyCodeToCharacter[keyCode] else { return keyCode }
    let map = layoutMap ?? currentKeyboardLayoutMap()
    return map[character] ?? keyCode
}

/// Parses a "+"-separated chord like "Ctrl+Shift+t" into one key + modifier flags.
public func parseKeyChord(_ chord: String) throws -> KeyChord {
    let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard !parts.isEmpty, !parts.contains("") else {
        throw SkyServiceError(code: .invalidParams, message: "empty key in chord '\(chord)'")
    }
    var flags: CGEventFlags = []
    var keyCode: CGKeyCode?
    for part in parts {
        let lowered = part.lowercased()
        if let flag = modifierFlags[lowered] {
            flags.insert(flag)
        } else if let code = keyCodes[lowered] {
            guard keyCode == nil else {
                throw SkyServiceError(code: .invalidParams, message: "chord '\(chord)' has more than one non-modifier key")
            }
            keyCode = code
        } else {
            throw SkyServiceError(code: .invalidParams, message: "unknown key '\(part)' in chord '\(chord)'")
        }
    }
    guard let code = keyCode else {
        throw SkyServiceError(code: .invalidParams, message: "chord '\(chord)' has no non-modifier key")
    }
    return KeyChord(keyCode: code, flags: flags)
}
