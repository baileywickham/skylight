import AppKit
import ApplicationServices
import Foundation

/// Replaces newlines/control characters with spaces and length-caps the result,
/// so one AX value (e.g. a multi-line AXTextArea) can neither break the
/// serializer's one-node-per-line invariant nor bloat get_app_state output.
public func sanitizeAXText(_ raw: String, maxLength: Int = 200) -> String {
    let space: Unicode.Scalar = " "
    let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
        if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
            return space
        }
        return scalar
    }))
    guard cleaned.count > maxLength else { return cleaned }
    return String(cleaned.prefix(maxLength)) + "…"
}

/// Live TreeNode over an AXUIElement. Children are fetched eagerly at init so
/// the serializer's walk stays pure.
struct LiveAXNode: TreeNode {
    let element: AXUIElement
    var identity: AnyHashable { AXIdentity(element: element) }
    var role: String { sanitizeAXText(axAttribute(element, kAXRoleAttribute) ?? "AXUnknown") }
    var title: String? {
        (axAttribute(element, kAXTitleAttribute) as String?).map { sanitizeAXText($0) }
    }
    var value: String? {
        let raw: CFTypeRef? = axAttribute(element, kAXValueAttribute)
        if let s = raw as? String { return sanitizeAXText(s) }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    var children: [any TreeNode] {
        let kids: [AXUIElement] = (axAttribute(element, kAXChildrenAttribute) as CFArray?)
            .map { cfArray -> [AXUIElement] in
                // `is`/`as?` do NOT discriminate CF types at runtime (verified: they
                // pass CFString/CFNumber through), so filter by CFTypeID — after
                // which the downcast is provably safe.
                let array = cfArray as [AnyObject]
                return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                    .map { unsafeDowncast($0, to: AXUIElement.self) }
            } ?? []
        return kids.map { LiveAXNode(element: $0) }
    }
}

public struct CaptureResult {
    public let text: String
    public let lines: [TreeLine]
    public let window: AXUIElement
    public let geometry: CaptureGeometry
    public let diffed: Bool

    public init(text: String, lines: [TreeLine], window: AXUIElement,
                geometry: CaptureGeometry, diffed: Bool) {
        self.text = text
        self.lines = lines
        self.window = window
        self.geometry = geometry
        self.diffed = diffed
    }
}

/// Per-app capture state: the sticky index map, the previous serialized lines
/// (for M2 diffing), and the geometry of the latest capture.
final class AppCaptureState {
    let map = ElementIndexMap()
    var previousLines: [TreeLine]?
    var latestGeometry: CaptureGeometry?
    var enablementDone = false
}

/// NOT thread-safe (ElementIndexMap and per-pid state are unsynchronized):
/// all capture and index resolution must stay on the daemon's global serial
/// actuation queue, where the router already runs handlers.
public final class AXCapture {
    private let caps: TreeCaps
    private let messagingTimeout: Float
    private var stateByPid: [pid_t: AppCaptureState] = [:]

    public init(caps: TreeCaps = .standard, messagingTimeout: Float = 0.25) {
        self.caps = caps
        self.messagingTimeout = messagingTimeout
    }

    private func state(for pid: pid_t) -> AppCaptureState {
        if let existing = stateByPid[pid] { return existing }
        let fresh = AppCaptureState()
        stateByPid[pid] = fresh
        return fresh
    }

    public func focusedWindow(of app: NSRunningApplication) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        if let focused: AXUIElement = axAttribute(appElement, kAXFocusedWindowAttribute) {
            return focused
        }
        if let main: AXUIElement = axAttribute(appElement, kAXMainWindowAttribute) {
            return main
        }
        let windows: [AXUIElement] = (axAttribute(appElement, kAXWindowsAttribute) as CFArray?)
            .map { cfArray -> [AXUIElement] in
                // See children in LiveAXNode: CFTypeID is the only runtime-correct
                // filter for CF types; `is AXUIElement` is vacuously true.
                let array = cfArray as [AnyObject]
                return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                    .map { unsafeDowncast($0, to: AXUIElement.self) }
            } ?? []
        guard let first = windows.first else {
            throw SkyServiceError(code: .noFocusedWindow,
                                  message: "\(app.localizedName ?? "app") has no focused window")
        }
        return first
    }

    /// Capture with diff-by-default (Milestone 2): when a previous capture of
    /// the same app exists and `disableDiff == false`, returns only the
    /// added/removed/changed lines keyed by sticky index; otherwise the full
    /// tree.
    ///
    /// Does NOT advance the diff baseline: the caller must invoke
    /// `commitBaseline(_:forPid:)` once the full get_app_state response
    /// (including the screenshot) has been produced. Otherwise a capture whose
    /// screenshot fails would advance the baseline to a tree the model never
    /// saw, and the next diff would silently omit the intervening changes.
    /// (The sticky ElementIndexMap does advance during the walk; indices are
    /// monotonic, so that is safe regardless of response delivery.)
    public func capture(app: NSRunningApplication, disableDiff: Bool) throws -> CaptureResult {
        guard Permissions.status().accessibility else {
            let instructions = Permissions.instructions(
                for: PermissionStatus(accessibility: false, screen_recording: true))
            throw SkyServiceError(code: .permissionDenied,
                                  message: instructions.joined(separator: " "))
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // A hung target degrades to truncated output, not a 6s-per-call stall.
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        let s = state(for: pid)
        if !s.enablementDone {
            // Chromium/Electron apps expose an empty tree until an assistive
            // client flips these; harmless for apps that ignore them.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            s.enablementDone = true
            usleep(300_000) // settle before the first real walk
        }

        let window = try focusedWindow(of: app)
        let geometry = try captureGeometry(for: window)
        let serialized = AXTreeSerializer(caps: caps).serialize(root: LiveAXNode(element: window), map: s.map)

        // Milestone 2: diff-by-default on the sticky index map; disableDiff honored.
        let outputText: String
        let diffed: Bool
        if !disableDiff, let previous = s.previousLines {
            outputText = diffTrees(previous: previous, current: serialized.lines)
            diffed = true
        } else {
            outputText = serialized.text
            diffed = false
        }

        return CaptureResult(text: outputText, lines: serialized.lines,
                             window: window, geometry: geometry, diffed: diffed)
    }

    /// Commits a capture as the new diff baseline (and coordinate geometry)
    /// for `pid`. Call only after the capture's full response — including the
    /// screenshot — succeeded, so the baseline never advances past a tree the
    /// model never received. Must run on the daemon's serial actuation queue,
    /// like every other AXCapture call.
    public func commitBaseline(_ result: CaptureResult, forPid pid: pid_t) {
        let s = state(for: pid)
        s.previousLines = result.lines
        s.latestGeometry = result.geometry
    }

    /// True when a committed diff baseline exists for `pid` — lets tests
    /// assert that a failed capture path leaves the baseline untouched.
    public func hasBaseline(forPid pid: pid_t) -> Bool {
        stateByPid[pid]?.previousLines != nil
    }

    /// Resolves an element_index back to its live AXUIElement for action calls.
    public func element(forIndex index: Int, appPid pid: pid_t) throws -> AXUIElement {
        guard let identity = stateByPid[pid]?.map.identity(forIndex: index),
              let axIdentity = identity as? AXIdentity else {
            throw SkyServiceError(code: .staleElementIndex,
                                  message: "element_index \(index) is unknown for this app — call get_app_state and retry")
        }
        if !(stateByPid[pid]?.map.isInLatestCapture(index) ?? false) {
            throw SkyServiceError(code: .staleElementIndex,
                                  message: "element_index \(index) disappeared from the latest capture — call get_app_state and retry")
        }
        return axIdentity.element
    }

    public func latestGeometry(forPid pid: pid_t) -> CaptureGeometry? {
        stateByPid[pid]?.latestGeometry
    }
}
