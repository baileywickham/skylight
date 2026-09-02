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

/// Picks the label for a node. AXTitle wins; when the title AND the value are
/// both empty (an otherwise anonymous node, e.g. Calculator's SwiftUI buttons,
/// which expose their name via other attributes), falls back to AXDescription,
/// then AXHelp, then AXIdentifier. The fallbacks are autoclosures so the extra
/// AX round-trips only happen for title-less nodes.
public func fallbackAXLabel(title: String?, value: String?,
                            description: @autoclosure () -> String?,
                            help: @autoclosure () -> String?,
                            identifier: @autoclosure () -> String?) -> String? {
    if let title, !title.isEmpty { return title }
    if let value, !value.isEmpty { return nil } // value renders separately; node isn't anonymous
    if let description = description(), !description.isEmpty { return description }
    if let help = help(), !help.isEmpty { return help }
    if let identifier = identifier(), !identifier.isEmpty { return identifier }
    return nil
}

/// Live TreeNode over an AXUIElement. Children are fetched eagerly at init so
/// the serializer's walk stays pure.
struct LiveAXNode: TreeNode {
    let element: AXUIElement
    var identity: AnyHashable { AXIdentity(element: element) }
    var role: String { sanitizeAXText(axAttribute(element, kAXRoleAttribute) ?? "AXUnknown") }
    var title: String? {
        fallbackAXLabel(title: axAttribute(element, kAXTitleAttribute),
                        value: value,
                        description: axAttribute(self.element, kAXDescriptionAttribute),
                        help: axAttribute(self.element, kAXHelpAttribute),
                        identifier: axAttribute(self.element, kAXIdentifierAttribute))
            .map { sanitizeAXText($0) }
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

/// True when the first capture after AX enablement (Chromium's
/// AXManualAccessibility/AXEnhancedUserInterface) produced a tree without any
/// web content — the settle was too short and one re-walk is warranted.
public func needsWebAreaRetry(enablementJustApplied: Bool, lines: [TreeLine]) -> Bool {
    enablementJustApplied && !hasWebArea(lines)
}

public func hasWebArea(_ lines: [TreeLine]) -> Bool {
    lines.contains { $0.text.contains("AXWebArea") }
}

/// Chromium drops its accessibility tree when a window is occluded or moved to
/// the background long enough, and the AXManualAccessibility flag that made it
/// publish one is applied only on the app's FIRST capture. Background agents
/// work on exactly such windows, so without this a long background session
/// silently degrades to an empty tree.
///
/// Re-enable only on the transition — an app that has published web content
/// before and now has none. An app that never had a web area (every AppKit app)
/// must not pay for a re-enable on every capture.
public func shouldReapplyEnablement(previouslyHadWebArea: Bool, currentHasWebArea: Bool) -> Bool {
    previouslyHadWebArea && !currentHasWebArea
}

/// Window-aware diff gate: diff only against a baseline from the SAME window.
/// When either window id is unknown (private bridge unavailable) fall back to
/// the original per-app behavior — better an occasional cross-window diff on
/// bridge-less machines than never diffing at all there.
public func canDiff(disableDiff: Bool, hasPrevious: Bool,
                    previousWindowID: Int?, currentWindowID: Int?) -> Bool {
    guard !disableDiff, hasPrevious else { return false }
    guard let prev = previousWindowID, let cur = currentWindowID else { return true }
    return prev == cur
}

public struct CaptureResult {
    public let text: String
    public let lines: [TreeLine]
    public let window: AXUIElement
    public let geometry: CaptureGeometry
    public let windowID: Int?
    public let diffed: Bool

    public init(text: String, lines: [TreeLine], window: AXUIElement,
                geometry: CaptureGeometry, windowID: Int?, diffed: Bool) {
        self.text = text
        self.lines = lines
        self.window = window
        self.geometry = geometry
        self.windowID = windowID
        self.diffed = diffed
    }
}

/// Per-app capture state: the sticky index map, the previous serialized lines
/// (for M2 diffing), and the geometry of the latest capture.
final class AppCaptureState {
    let map = ElementIndexMap()
    var previousLines: [TreeLine]?
    var previousWindowID: Int?
    var latestGeometry: CaptureGeometry?
    var enablementDone = false
    /// Whether this app has ever published web content, so a later capture that
    /// lost it can be recognized as a dropped tree rather than a native app.
    var hadWebArea = false
}

/// Safe for concurrent use across DIFFERENT pids only.
///
/// All capture state is partitioned per pid, so requests for different apps
/// touch disjoint `AppCaptureState` objects; the lock below guards just the
/// lookup table that hands them out. An individual `AppCaptureState` (and the
/// `ElementIndexMap` inside it) is still unsynchronized, which is sound because
/// `ActuationScheduler` serializes every request that shares an app key — see
/// RequestClassifier. Two concurrent requests for the SAME pid would corrupt
/// the index map, and the scheduler is what prevents that.
public final class AXCapture {
    private let caps: TreeCaps
    private let messagingTimeout: Float
    private let webAreaRetrySeconds: TimeInterval
    /// Guards `stateByPid` itself. Held only for the dictionary access, never
    /// across an AX call — those are slow and must not serialize other apps.
    private let stateLock = NSLock()
    private var stateByPid: [pid_t: AppCaptureState] = [:]

    public init(caps: TreeCaps = .standard, messagingTimeout: Float = 0.25,
                webAreaRetrySeconds: TimeInterval = 2.5) {
        self.caps = caps
        self.messagingTimeout = messagingTimeout
        self.webAreaRetrySeconds = webAreaRetrySeconds
    }

    private func state(for pid: pid_t) -> AppCaptureState {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = stateByPid[pid] { return existing }
        let fresh = AppCaptureState()
        stateByPid[pid] = fresh
        return fresh
    }

    /// Read-only peek that does not create state for an unseen pid.
    private func existingState(for pid: pid_t) -> AppCaptureState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateByPid[pid]
    }

    /// kAXWindowsAttribute → [AXUIElement]. CFTypeID is the only runtime-correct
    /// filter for CF types; `is AXUIElement` is vacuously true (see LiveAXNode).
    private func windowElements(of appElement: AXUIElement) -> [AXUIElement] {
        (axAttribute(appElement, kAXWindowsAttribute) as CFArray?)
            .map { cfArray -> [AXUIElement] in
                let array = cfArray as [AnyObject]
                return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                    .map { unsafeDowncast($0, to: AXUIElement.self) }
            } ?? []
    }

    /// What a capture/action targets: a normal window, or — for window-less
    /// menu-bar apps — the extras menu bar + popover surfaces.
    enum CaptureTarget {
        case window(AXUIElement)
        case menuBar(MenuBarAppTarget)

        /// The element geometry, screenshots, raises, and scroll clamping use.
        var surface: AXUIElement {
            switch self {
            case .window(let w): return w
            case .menuBar(let t): return t.surface
            }
        }
    }

    func resolveTarget(of app: NSRunningApplication) throws -> CaptureTarget {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        if let focused: AXUIElement = axAttribute(appElement, kAXFocusedWindowAttribute) {
            return .window(focused)
        }
        if let main: AXUIElement = axAttribute(appElement, kAXMainWindowAttribute) {
            return .window(main)
        }
        if let first = windowElements(of: appElement).first {
            return .window(first)
        }
        // Menu-bar (accessory) apps: no AXWindows at all — target the status
        // item / open popover instead.
        if let target = menuBarTarget(of: appElement) {
            return .menuBar(target)
        }
        throw SkyServiceError(code: .noFocusedWindow,
                              message: "\(app.localizedName ?? "app") has no window or menu bar extra")
    }

    public func focusedWindow(of app: NSRunningApplication) throws -> AXUIElement {
        try resolveTarget(of: app).surface
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
    public func capture(app: NSRunningApplication, windowID: Int? = nil, disableDiff: Bool) throws -> CaptureResult {
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
        var enablementJustApplied = false
        if !s.enablementDone {
            // Chromium/Electron apps expose an empty tree until an assistive
            // client flips these; harmless for apps that ignore them. (The set
            // return codes cannot identify Chromium — verified live: Chrome
            // rejects both sets just like TextEdit yet still honors them — so
            // the retry below is gated only on this being the first capture.)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            s.enablementDone = true
            enablementJustApplied = true
            usleep(300_000) // settle before the first real walk
        }

        let target: CaptureTarget
        if let id = windowID {
            guard let match = try windowListings(of: app).first(where: { $0.info.window_id == id }) else {
                throw SkyServiceError(code: .noFocusedWindow,
                                      message: "window_id \(id) not found for '\(app.localizedName ?? "app")' — call list_windows for current ids")
            }
            target = .window(match.element)
        } else {
            target = try resolveTarget(of: app)
        }
        // Menu-bar apps serialize from a synthetic root spanning the status
        // item AND the popover — the popover is a detached AX subtree, so a
        // single-element root would show one or the other, never both.
        let window = target.surface
        let root: any TreeNode
        switch target {
        case .window(let w): root = LiveAXNode(element: w)
        case .menuBar(let t): root = MenuBarAppRoot(appElement: appElement, target: t)
        }
        let currentWindowID = axWindowID(of: window).map { Int($0) }
        let geometry = try captureGeometry(for: window)
        var serialized = AXTreeSerializer(caps: caps).serialize(root: root, map: s.map)
        // Right after enablement Chromium can take a while (>1s cold, verified
        // live) to publish its web content, leaving the first walk without an
        // AXWebArea. Poll with a bounded budget — only on the enablement
        // capture and only while web content is absent — instead of a long
        // unconditional delay on every capture. (Chromium can't be identified
        // cheaply: its app element rejects/lists the same attributes as AppKit
        // apps, so non-web apps pay this budget once, on first capture only.)
        if enablementJustApplied {
            let deadline = Date().addingTimeInterval(webAreaRetrySeconds)
            while needsWebAreaRetry(enablementJustApplied: true, lines: serialized.lines),
                  Date() < deadline {
                usleep(500_000)
                serialized = AXTreeSerializer(caps: caps).serialize(root: root, map: s.map)
            }
        } else if shouldReapplyEnablement(previouslyHadWebArea: s.hadWebArea,
                                          currentHasWebArea: hasWebArea(serialized.lines)) {
            // The app published web content before and has none now — an
            // occluded/backgrounded Chromium window that dropped its tree.
            // Re-flip the enablement flags and re-walk once.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            usleep(300_000)
            serialized = AXTreeSerializer(caps: caps).serialize(root: root, map: s.map)
        }
        if hasWebArea(serialized.lines) { s.hadWebArea = true }

        // Milestone 2: diff-by-default on the sticky index map; disableDiff honored.
        // M3: window-aware — a window change forces a full tree (see canDiff).
        let outputText: String
        let diffed: Bool
        if canDiff(disableDiff: disableDiff, hasPrevious: s.previousLines != nil,
                   previousWindowID: s.previousWindowID, currentWindowID: currentWindowID),
           let previous = s.previousLines {
            outputText = diffTrees(previous: previous, current: serialized.lines)
            diffed = true
        } else {
            outputText = serialized.text
            diffed = false
        }

        return CaptureResult(text: outputText, lines: serialized.lines, window: window,
                             geometry: geometry, windowID: currentWindowID, diffed: diffed)
    }

    /// One entry per AX window of the app, with the wire-facing WindowInfo and
    /// the live element (used by window_id-targeted capture). Ordered as the
    /// app reports kAXWindowsAttribute.
    public struct WindowListing {
        public let element: AXUIElement
        public let info: WindowInfo
    }

    public func windowListings(of app: NSRunningApplication) throws -> [WindowListing] {
        guard Permissions.status().accessibility else {
            let instructions = Permissions.instructions(
                for: PermissionStatus(accessibility: false, screen_recording: true))
            throw SkyServiceError(code: .permissionDenied,
                                  message: instructions.joined(separator: " "))
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let focused: AXUIElement? = axAttribute(appElement, kAXFocusedWindowAttribute)
        let wins = windowElements(of: appElement)
        return wins.map { w in
            let minimized: NSNumber? = axAttribute(w, kAXMinimizedAttribute)
            let title: String? = axAttribute(w, kAXTitleAttribute)
            let windowID = axWindowID(of: w)
            return WindowListing(element: w, info: WindowInfo(
                window_id: windowID.map { Int($0) },
                title: title.map { sanitizeAXText($0) },
                is_focused: focused.map { CFEqual($0, w) } ?? false,
                is_minimized: minimized?.boolValue ?? false,
                is_on_active_space: windowID.flatMap { SkyLightBridge.isOnActiveSpace(windowID: $0) }))
        }
    }

    /// Commits a capture as the new diff baseline (and coordinate geometry)
    /// for `pid`. Call only after the capture's full response — including the
    /// screenshot — succeeded, so the baseline never advances past a tree the
    /// model never received. Must run on the daemon's serial actuation queue,
    /// like every other AXCapture call.
    public func commitBaseline(_ result: CaptureResult, forPid pid: pid_t) {
        let s = state(for: pid)
        s.previousLines = result.lines
        s.previousWindowID = result.windowID
        s.latestGeometry = result.geometry
    }

    /// True when a committed diff baseline exists for `pid` — lets tests
    /// assert that a failed capture path leaves the baseline untouched.
    public func hasBaseline(forPid pid: pid_t) -> Bool {
        existingState(for: pid)?.previousLines != nil
    }

    /// Resolves an element_index back to its live AXUIElement for action calls.
    public func element(forIndex index: Int, appPid pid: pid_t) throws -> AXUIElement {
        let s = existingState(for: pid)
        guard let identity = s?.map.identity(forIndex: index),
              let axIdentity = identity as? AXIdentity else {
            throw SkyServiceError(code: .staleElementIndex,
                                  message: "element_index \(index) is unknown for this app — call get_app_state and retry")
        }
        if !(s?.map.isInLatestCapture(index) ?? false) {
            throw SkyServiceError(code: .staleElementIndex,
                                  message: "element_index \(index) disappeared from the latest capture — call get_app_state and retry")
        }
        return axIdentity.element
    }

    public func latestGeometry(forPid pid: pid_t) -> CaptureGeometry? {
        existingState(for: pid)?.latestGeometry
    }

    /// Window id of the last committed capture for `pid` (nil if none or the
    /// bridge couldn't resolve one). Coordinate actions raise THIS window so
    /// events land where the geometry says they will.
    public func latestWindowID(forPid pid: pid_t) -> Int? {
        existingState(for: pid)?.previousWindowID
    }
}
