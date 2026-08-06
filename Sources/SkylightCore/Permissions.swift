import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public struct PermissionStatus: Codable, Equatable {
    public let accessibility: Bool
    public let screen_recording: Bool
    public init(accessibility: Bool, screen_recording: Bool) {
        self.accessibility = accessibility
        self.screen_recording = screen_recording
    }
}

public enum Permissions {
    public static func status() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            screen_recording: CGPreflightScreenCaptureAccess())
    }

    /// Asks macOS for Screen Recording. Returns whether it is granted.
    ///
    /// This exists because `CGPreflightScreenCaptureAccess` only CHECKS, and
    /// `Screenshotter` refuses to capture when that check fails — so without an
    /// explicit request the daemon never touches ScreenCaptureKit, macOS is
    /// never asked, no prompt appears, and the app never gets listed under
    /// Screen & System Audio Recording. The user is then told to "enable
    /// SkylightService" in a list that does not contain it. Requesting once at
    /// startup breaks that deadlock.
    ///
    /// Safe to call when already granted (returns true, shows nothing) and when
    /// the user has previously denied (macOS declines to re-prompt; they must
    /// use the pane's Add button).
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// One precise line per missing grant, naming the exact System Settings pane.
    public static func instructions(for status: PermissionStatus) -> [String] {
        var lines: [String] = []
        if !status.accessibility {
            lines.append("Accessibility NOT granted: open System Settings > Privacy & Security > Accessibility and enable SkylightService.")
        }
        if !status.screen_recording {
            lines.append("Screen Recording NOT granted (or lapsed — macOS 15+ re-prompts periodically): open System Settings > Privacy & Security > Screen & System Audio Recording and enable SkylightService.")
        }
        return lines
    }

    /// True when something is accepting connections on the socket.
    public static func socketIsLive(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBufferPointer { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, 104)))
            }
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}
