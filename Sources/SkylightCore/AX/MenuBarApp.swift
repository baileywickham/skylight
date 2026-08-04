import AppKit
import ApplicationServices
import Foundation

/// Menu-bar (LSUIElement/accessory) apps have no AXWindows: their UI is a
/// status item in the extras menu bar plus, when open, a transient popover.
/// Where the popover hangs in the AX tree varies with key status (verified
/// live against an NSStatusItem + NSPopover app): while its window is key it
/// is DETACHED — the status item's AXChildren is empty and the popover is
/// reachable only via the app's AXFocusedUIElement, whose focused element may
/// be a control nested inside it; once it loses key status (focus moved to
/// another app but the popover stays open) it appears as a child of the menu
/// bar item. AXTopLevelUIElement is no help in either state: for popover
/// content it reports the extras menu bar, not the popover. So the focused
/// path must climb AXParent links until an AXPopover appears.
///
/// Generic over the element handle + lookups so the climb (including its
/// cycle/hop bound) is unit-testable with fixtures.
public func climbToPopover<E>(from element: E, maxHops: Int = 12,
                              role: (E) -> String?, parent: (E) -> E?) -> E? {
    var current: E? = element
    for _ in 0...maxHops {
        guard let e = current else { return nil }
        if role(e) == "AXPopover" { return e }
        current = parent(e)
    }
    return nil
}

/// The two live UI surfaces of a menu-bar app.
struct MenuBarAppTarget {
    /// The extras menu bar element (contains the app's status item(s)).
    let extrasBar: AXUIElement
    /// The open popover, if any.
    let popover: AXUIElement?
    /// true when the popover was found inside the extras-bar subtree (non-key
    /// state): it then serializes as part of the extras walk and the root must
    /// not append it a second time.
    let popoverAttached: Bool

    /// Geometry/screenshot surface: the popover shows the app's actual UI, so
    /// it wins whenever open; otherwise the status item strip itself.
    var surface: AXUIElement { popover ?? extrasBar }
}

private func axChildElements(of element: AXUIElement) -> [AXUIElement] {
    // CFTypeID is the only runtime-correct filter for CF types (see LiveAXNode).
    (axAttribute(element, kAXChildrenAttribute) as CFArray?)
        .map { cfArray -> [AXUIElement] in
            let array = cfArray as [AnyObject]
            return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                .map { unsafeDowncast($0, to: AXUIElement.self) }
        } ?? []
}

/// Resolves the menu-bar surfaces of `appElement`, or nil when the app has no
/// extras menu bar (then it truly has no UI to target). The popover is looked
/// up in both of its possible attachment points (see file header): as a child
/// of a status item first, then via the focused-element parent climb.
func menuBarTarget(of appElement: AXUIElement) -> MenuBarAppTarget? {
    guard let extras: AXUIElement = axAttribute(appElement, "AXExtrasMenuBar") else { return nil }
    for item in axChildElements(of: extras) {
        if let popover = axChildElements(of: item).first(where: {
            (axAttribute($0, kAXRoleAttribute) as String?) == "AXPopover"
        }) {
            return MenuBarAppTarget(extrasBar: extras, popover: popover, popoverAttached: true)
        }
    }
    let popover = (axAttribute(appElement, kAXFocusedUIElementAttribute) as AXUIElement?)
        .flatMap { focused in
            climbToPopover(from: focused,
                           role: { axAttribute($0, kAXRoleAttribute) },
                           parent: { axAttribute($0, kAXParentAttribute) })
        }
    return MenuBarAppTarget(extrasBar: extras, popover: popover, popoverAttached: false)
}

/// Serialization root for a menu-bar app: one synthetic node over the extras
/// menu bar and the open popover, so the status item stays clickable in the
/// same capture that shows the popover contents. Identity is the app element,
/// which is stable across captures — the sticky index map and diffing behave
/// exactly as they do for a window root.
struct MenuBarAppRoot: TreeNode {
    let appElement: AXUIElement
    let target: MenuBarAppTarget

    var identity: AnyHashable { AXIdentity(element: appElement) }
    var role: String { "AXMenuBarApp" }
    var title: String? {
        (axAttribute(appElement, kAXTitleAttribute) as String?).map { sanitizeAXText($0) }
    }
    var value: String? { nil }
    var children: [any TreeNode] {
        var kids: [any TreeNode] = [LiveAXNode(element: target.extrasBar)]
        if let popover = target.popover, !target.popoverAttached {
            kids.append(LiveAXNode(element: popover))
        }
        return kids
    }
}
