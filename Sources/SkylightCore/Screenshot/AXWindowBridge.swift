import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private typealias AXGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// ScreenCaptureKit addresses windows by CGWindowID, but resolution produces an
/// AXUIElement. The exact mapping is the private _AXUIElementGetWindow symbol —
/// an accepted trade-off for a personal tool (spec: "Reference"). If it ever
/// disappears, the best-effort fallback is frame+title matching per the spec.
public func axWindowID(of window: AXUIElement) -> CGWindowID? {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow") else { return nil }
    let fn = unsafeBitCast(sym, to: AXGetWindowFunc.self)
    var windowID: CGWindowID = 0
    guard fn(window, &windowID) == .success, windowID != 0 else { return nil }
    return windowID
}
