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
    "alt": .maskAlternate, "option": .maskAlternate,
    "shift": .maskShift,
    "command": .maskCommand, "cmd": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
]

/// X-keysym-style names (lowercased) → macOS virtual key codes (ANSI layout).
private let keyCodes: [String: CGKeyCode] = {
    var map: [String: CGKeyCode] = [
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
