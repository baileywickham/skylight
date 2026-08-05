import CoreGraphics
import Foundation

/// Synthetic window-server event records for `SLPSPostEventRecordTo`.
///
/// These are opaque 0xf8-byte structures whose layout is undocumented; the
/// offsets below are the ones yabai has used (and kept working) for years, and
/// they are what lets an app be made AppKit-ACTIVE without being RAISED — the
/// whole basis of background actuation. Building them is pure, so every magic
/// offset is pinned by EventRecordTests: if a future edit shifts one, CI fails
/// instead of the record silently no-op'ing against a live window server.
public enum EventRecord {
    /// Size of one event record. Every byte outside the fields set below is 0.
    public static let size = 0xf8

    /// Offsets into the record. Named so the builders read as intent rather
    /// than as a wall of hex.
    private enum Offset {
        static let magic = 0x04        // always 0xf8
        static let kind = 0x08         // record kind
        static let fill = 0x20         // 0x10 bytes of 0xFF ("all displays" mask)
        static let keyWindowTag = 0x3a // 0x10 on the key-window records
        static let windowID = 0x3c     // little-endian UInt32
        static let activation = 0x8a   // 1 = activate, 2 = deactivate
    }

    private enum Kind {
        static let activation: UInt8 = 0x0d
        static let keyWindowFirst: UInt8 = 0x01
        static let keyWindowSecond: UInt8 = 0x02
    }

    private static let fillLength = 0x10

    private static func base(kind: UInt8, windowID: CGWindowID) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes[Offset.magic] = 0xf8
        bytes[Offset.kind] = kind
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (i, byte) in raw.enumerated() { bytes[Offset.windowID + i] = byte }
        }
        return bytes
    }

    private static func applyFill(_ bytes: inout [UInt8]) {
        for i in 0..<fillLength { bytes[Offset.fill + i] = 0xFF }
    }

    /// Flips a process's AppKit-active state. Sent to the process being
    /// deactivated (the current front app) and then to the one being activated.
    /// Only the activate record carries the 0xFF fill — matching yabai, whose
    /// deactivate record leaves it zeroed.
    public static func activation(windowID: CGWindowID, activate: Bool) -> [UInt8] {
        var bytes = base(kind: Kind.activation, windowID: windowID)
        bytes[Offset.activation] = activate ? 1 : 2
        if activate { applyFill(&bytes) }
        return bytes
    }

    /// The pair that makes `windowID` the app's key window, so keyboard input
    /// and menu key equivalents resolve against it. Both must be posted, in
    /// order, to the target process.
    public static func keyWindow(windowID: CGWindowID) -> [[UInt8]] {
        [Kind.keyWindowFirst, Kind.keyWindowSecond].map { kind in
            var bytes = base(kind: kind, windowID: windowID)
            bytes[Offset.keyWindowTag] = 0x10
            applyFill(&bytes)
            return bytes
        }
    }
}
