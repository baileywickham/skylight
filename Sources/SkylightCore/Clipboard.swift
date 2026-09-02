import AppKit
import Foundation

public struct ClipboardResult: Codable, Equatable {
    /// Plain-text contents, nil when the pasteboard holds no string flavor.
    public let text: String?
    /// UTIs present on the pasteboard, so a caller can tell "empty" from
    /// "an image is on the clipboard".
    public let types: [String]
    /// NSPasteboard change count — bumps on every write, by anyone.
    public let change_count: Int
    public init(text: String?, types: [String], change_count: Int) {
        self.text = text
        self.types = types
        self.change_count = change_count
    }
}

public struct WriteClipboardInput: Codable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// The general pasteboard. Not app-scoped, so neither method goes through
/// the approvals gate; `write` still respects the pause sentinel through the
/// daemon and is audit-logged like every other mutation.
///
/// AppKit documents NSPasteboard as main-thread-safe only, and handlers run
/// on the IPC queue, so both calls hop to the main queue (the daemon's
/// NSApplication run loop is always pumping there).
public enum Clipboard {
    public static func read() -> ClipboardResult {
        onMain {
            let pb = NSPasteboard.general
            return ClipboardResult(
                text: pb.string(forType: .string),
                types: (pb.types ?? []).map(\.rawValue),
                change_count: pb.changeCount)
        }
    }

    @discardableResult
    public static func write(text: String) -> ActionResult {
        onMain {
            let pb = NSPasteboard.general
            pb.clearContents()
            return ActionResult(done: pb.setString(text, forType: .string))
        }
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}
