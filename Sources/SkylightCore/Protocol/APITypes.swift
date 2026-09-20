import Foundation

public struct AppInfo: Codable, Equatable {
    public let name: String
    public let bundle_id: String?
    public let pid: Int32
    public let is_frontmost: Bool
    public let launch_date: String?
    /// true for accessory-policy (LSUIElement) apps — menu bar extras with a
    /// status item instead of windows. Absent for regular Dock apps.
    public let menu_bar_only: Bool?
    public init(name: String, bundle_id: String?, pid: Int32, is_frontmost: Bool, launch_date: String?,
                menu_bar_only: Bool? = nil) {
        self.name = name
        self.bundle_id = bundle_id
        self.pid = pid
        self.is_frontmost = is_frontmost
        self.launch_date = launch_date
        self.menu_bar_only = menu_bar_only
    }
}

public struct ListAppsInput: Codable, Equatable {
    /// Also list accessory-policy (menu bar) apps. Default false.
    public let include_menu_bar_apps: Bool?
    public init(include_menu_bar_apps: Bool? = nil) {
        self.include_menu_bar_apps = include_menu_bar_apps
    }
}

public struct ListAppsResult: Codable, Equatable {
    public let apps: [AppInfo]
    public init(apps: [AppInfo]) { self.apps = apps }
}

public struct WindowInfo: Codable, Equatable {
    /// CGWindowID from the _AXUIElementGetWindow bridge; nil when the private
    /// symbol is unavailable (window then can't be targeted by window_id).
    public let window_id: Int?
    public let title: String?
    public let is_focused: Bool
    public let is_minimized: Bool
    /// Whether the window is on the Space the user is looking at. Absent when
    /// the Spaces bridge is unavailable (see capabilities.skylight.space_management).
    public let is_on_active_space: Bool?
    public init(window_id: Int?, title: String?, is_focused: Bool, is_minimized: Bool,
                is_on_active_space: Bool? = nil) {
        self.window_id = window_id
        self.title = title
        self.is_focused = is_focused
        self.is_minimized = is_minimized
        self.is_on_active_space = is_on_active_space
    }
}

public struct ListWindowsResult: Codable, Equatable {
    public let windows: [WindowInfo]
    public init(windows: [WindowInfo]) { self.windows = windows }
}

public struct ListWindowsInput: Codable, Equatable {
    public let app: String
    public init(app: String) { self.app = app }
}

public struct ScreenshotResult: Codable, Equatable {
    public let url: String
    public let data_url: String?
    public let width: Int
    public let height: Int
    /// PNG pixels per screen point (2.0 on a Retina window at full size; lower
    /// when `max_dimension` downscaled it). Coordinates given back to click/
    /// drag are always pixels of THIS image, so callers never need it.
    public let scale: Double?
    public init(url: String, data_url: String?, width: Int, height: Int, scale: Double? = nil) {
        self.url = url
        self.data_url = data_url
        self.width = width
        self.height = height
        self.scale = scale
    }
}

// MARK: - Displays

public struct DisplayInfo: Codable, Equatable {
    /// CGDirectDisplayID — pass to screenshot/zoom/click as display_id.
    public let display_id: Int
    /// Size in points.
    public let width: Double
    public let height: Double
    /// Global top-left origin in points (the main display is 0,0; CGEvent space).
    public let origin_x: Double
    public let origin_y: Double
    /// Backing scale (2.0 on Retina).
    public let backing_scale: Double
    public let is_main: Bool
    public let name: String?
    public init(display_id: Int, width: Double, height: Double, origin_x: Double, origin_y: Double,
                backing_scale: Double, is_main: Bool, name: String?) {
        self.display_id = display_id
        self.width = width
        self.height = height
        self.origin_x = origin_x
        self.origin_y = origin_y
        self.backing_scale = backing_scale
        self.is_main = is_main
        self.name = name
    }
}

public struct ListDisplaysResult: Codable, Equatable {
    public let displays: [DisplayInfo]
    public init(displays: [DisplayInfo]) { self.displays = displays }
}

public struct ScreenshotInput: Codable, Equatable {
    /// Default: the main display.
    public let display_id: Int?
    /// Longest side of the PNG in pixels; the image is downscaled to fit.
    /// Default: 1 px per point (a 2x display is captured at 1x).
    public let max_dimension: Int?
    public let include_data_url: Bool?
    /// Draw the pointer. Default true — on a whole-desktop shot the cursor is
    /// useful context, unlike a window crop.
    public let show_cursor: Bool?
    public init(display_id: Int? = nil, max_dimension: Int? = nil, include_data_url: Bool? = nil,
                show_cursor: Bool? = nil) {
        self.display_id = display_id
        self.max_dimension = max_dimension
        self.include_data_url = include_data_url
        self.show_cursor = show_cursor
    }
}

/// A display (or display-region) capture. `global = origin + px / scale`.
public struct DisplayScreenshotResult: Codable, Equatable {
    public let display_id: Int
    public let url: String
    public let data_url: String?
    public let width: Int
    public let height: Int
    /// PNG pixels per screen point.
    public let scale: Double
    /// Global point of PNG pixel (0,0).
    public let origin_x: Double
    public let origin_y: Double
    public init(display_id: Int, url: String, data_url: String?, width: Int, height: Int,
                scale: Double, origin_x: Double, origin_y: Double) {
        self.display_id = display_id
        self.url = url
        self.data_url = data_url
        self.width = width
        self.height = height
        self.scale = scale
        self.origin_x = origin_x
        self.origin_y = origin_y
    }
}

public struct ZoomInput: Codable, Equatable {
    /// Zoom into this app's window instead of a display: the region is then
    /// pixels of its latest `get_app_state` capture — the same coordinates
    /// click/drag take — and the crop comes from a fresh capture of that
    /// window, so an occluded or background window still reads correctly.
    public let app: String?
    /// With `app`: a specific window (id from list_windows). Default: the
    /// window the latest capture targeted.
    public let window_id: Int?
    /// Without `app`: which display. Default: the main display.
    public let display_id: Int?
    /// Region in pixels of the latest image of that target: the `screenshot`
    /// of the display (points when there has been none), or with `app` the
    /// `get_app_state` window capture.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// Longest side cap; default: the target's native backing scale.
    public let max_dimension: Int?
    public let include_data_url: Bool?
    public init(app: String? = nil, window_id: Int? = nil, display_id: Int? = nil,
                x: Double, y: Double, width: Double, height: Double,
                max_dimension: Int? = nil, include_data_url: Bool? = nil) {
        self.app = app
        self.window_id = window_id
        self.display_id = display_id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.max_dimension = max_dimension
        self.include_data_url = include_data_url
    }
}

/// A zoomed crop. Exactly one of `display_id` / `window_id` identifies what it
/// came from; `origin_x/y` is the global point of pixel (0,0) either way.
public struct ZoomResult: Codable, Equatable {
    public let display_id: Int?
    public let window_id: Int?
    public let url: String
    public let data_url: String?
    public let width: Int
    public let height: Int
    /// PNG pixels per screen point.
    public let scale: Double
    public let origin_x: Double
    public let origin_y: Double
    public init(display_id: Int? = nil, window_id: Int? = nil, url: String, data_url: String?,
                width: Int, height: Int, scale: Double, origin_x: Double, origin_y: Double) {
        self.display_id = display_id
        self.window_id = window_id
        self.url = url
        self.data_url = data_url
        self.width = width
        self.height = height
        self.scale = scale
        self.origin_x = origin_x
        self.origin_y = origin_y
    }
}

// MARK: - Spaces

public struct BringToActiveSpaceInput: Codable, Equatable {
    public let app: String
    /// Default: the app's focused window.
    public let window_id: Int?
    public init(app: String, window_id: Int? = nil) {
        self.app = app
        self.window_id = window_id
    }
}

public struct BringToActiveSpaceResult: Codable, Equatable {
    public let window_id: Int
    /// True when the window is on the active Space after the call.
    public let on_active_space: Bool
    /// True when this call moved it (false when it was already there).
    public let moved: Bool
    public init(window_id: Int, on_active_space: Bool, moved: Bool) {
        self.window_id = window_id
        self.on_active_space = on_active_space
        self.moved = moved
    }
}

public struct AppState: Codable, Equatable {
    public let text: String
    /// nil when the screenshot failed but the AX capture succeeded (AX-only
    /// degraded response); `screenshot_error` then says why.
    public let screenshot: ScreenshotResult?
    public let screenshot_error: String?
    public let diffed: Bool
    public init(text: String, screenshot: ScreenshotResult?, screenshot_error: String? = nil, diffed: Bool) {
        self.text = text
        self.screenshot = screenshot
        self.screenshot_error = screenshot_error
        self.diffed = diffed
    }
}

/// What this daemon on this machine can actually do. Lets a client tell a
/// degraded install (missing TCC grant, or a macOS release that dropped a
/// private symbol) from a working one, instead of inferring it from flaky
/// background actions.
public struct CapabilitiesResult: Codable, Equatable {
    public let version: String
    public let permissions: PermissionStatus
    public let skylight: SkyLightCapabilities
    /// The configured mode: "auto" | "on" | "off" (see `BackgroundMode`).
    public let background_mode: String
    /// What `background_mode` resolves to right now: the effective value for
    /// a request that sets no `background` field.
    public let background_default: Bool
    /// True when actions against DIFFERENT apps can run concurrently. Requests
    /// for one app are always serialized, and foreground actions always run
    /// alone.
    public let parallel_actuation: Bool

    public init(version: String, permissions: PermissionStatus, skylight: SkyLightCapabilities,
                background_mode: String, background_default: Bool, parallel_actuation: Bool) {
        self.version = version
        self.permissions = permissions
        self.skylight = skylight
        self.background_mode = background_mode
        self.background_default = background_default
        self.parallel_actuation = parallel_actuation
    }
}

public struct ActionResult: Codable, Equatable {
    public let done: Bool
    public init(done: Bool) { self.done = done }
}

public struct GetAppStateInput: Codable, Equatable {
    public let app: String
    /// Target a specific window (id from list_windows). Default: focused window.
    public let window_id: Int?
    public let disableDiff: Bool?
    public let include_data_url: Bool?
    /// Longest side of the screenshot in pixels; downscaled to fit. Default:
    /// native backing scale. Click/drag coordinates stay pixels of the image
    /// returned, whatever the scale.
    public let max_dimension: Int?
    /// Tree depth budget for this capture (default 60). Raise it when the tree
    /// comes back with a "max depth … reached" marker over the part you need —
    /// deep Chromium/Electron web content is the usual cause.
    public let max_depth: Int?
    /// Node budget for this capture (default 5000).
    public let max_nodes: Int?
    /// Serialize only the subtree under this element (an index from an earlier
    /// capture) instead of the whole window — the pane you are working in, so
    /// an unrelated webview's churn stays out of the tree and out of the diff.
    /// The screenshot and click geometry still describe the whole window, so
    /// coordinates mean the same thing either way.
    public let root_element_index: Int?
    public init(app: String, window_id: Int? = nil, disableDiff: Bool? = nil, include_data_url: Bool? = nil,
                max_dimension: Int? = nil, max_depth: Int? = nil, max_nodes: Int? = nil,
                root_element_index: Int? = nil) {
        self.app = app
        self.window_id = window_id
        self.disableDiff = disableDiff
        self.include_data_url = include_data_url
        self.max_dimension = max_dimension
        self.max_depth = max_depth
        self.max_nodes = max_nodes
        self.root_element_index = root_element_index
    }
}

public struct ClickInput: Codable, Equatable {
    /// Required for element_index and window-coordinate clicks. Optional with
    /// display_id: the app under the point is hit-tested (frontmost app as
    /// fallback) and approval-checked like any other target.
    public let app: String?
    public let element_index: Int?
    public let x: Double?
    public let y: Double?
    /// When set, x/y are pixels of the latest `screenshot` of this display
    /// instead of the latest get_app_state window capture.
    public let display_id: Int?
    public let mouse_button: String?   // "left" | "right" | "middle"
    public let click_count: Int?
    /// Move the pointer onto the point before pressing (default true, and only
    /// for coordinate clicks — an element_index click is an AX press, which has
    /// no pointer). A real click always follows a pointer move, and hover-only
    /// affordances never render without one. Pass false to press without it.
    public let hover: Bool?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, element_index: Int? = nil, x: Double? = nil, y: Double? = nil,
                display_id: Int? = nil, mouse_button: String? = nil, click_count: Int? = nil,
                hover: Bool? = nil, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.x = x
        self.y = y
        self.display_id = display_id
        self.mouse_button = mouse_button
        self.click_count = click_count
        self.hover = hover
        self.background = background
    }
}

/// Park the pointer over an element or point without clicking, so hover-only
/// UI (Chromium/Electron row affordances, tooltips, hover menus) renders and
/// the next `get_app_state` can see it. In background mode the event is posted
/// into the app and the user's real cursor never moves.
public struct HoverInput: Codable, Equatable {
    /// Required for element_index and window-coordinate hovers; optional with
    /// display_id (the app under the point is hit-tested).
    public let app: String?
    public let element_index: Int?
    public let x: Double?
    public let y: Double?
    /// When set, x/y are pixels of the latest `screenshot` of this display.
    public let display_id: Int?
    /// Milliseconds to hold the pointer there before returning, so a hover
    /// that animates in has landed by the time the caller re-captures.
    /// Default 250, capped at 5000.
    public let settle_ms: Int?
    public let background: Bool?
    public init(app: String? = nil, element_index: Int? = nil, x: Double? = nil, y: Double? = nil,
                display_id: Int? = nil, settle_ms: Int? = nil, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.x = x
        self.y = y
        self.display_id = display_id
        self.settle_ms = settle_ms
        self.background = background
    }
}

public struct PressKeyInput: Codable, Equatable {
    /// Default: the frontmost app.
    public let app: String?
    public let keys: String            // "+"-separated chord, e.g. "Ctrl+Shift+t"
    /// Send the chord this many times (default 1, capped at
    /// `maxKeyRepeat`). One call for "delete the last 20 characters" instead
    /// of 20 round trips; the chord grammar has no room for a repeat because
    /// "BackSpace BackSpace" is not a chord.
    public let `repeat`: Int?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, keys: String, repeat repeatCount: Int? = nil, background: Bool? = nil) {
        self.app = app
        self.keys = keys
        self.`repeat` = repeatCount
        self.background = background
    }
}

public struct TypeTextInput: Codable, Equatable {
    /// Default: the frontmost app.
    public let app: String?
    public let text: String
    /// Focus this element before typing (needs `app`). Without it the text
    /// goes wherever focus happens to be — which, when a click did not take or
    /// the page moved focus on its own, is another field or nowhere at all,
    /// and the call still reports success. With it, a field that will not take
    /// focus is an error instead of text in the wrong place.
    public let element_index: Int?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, text: String, element_index: Int? = nil, background: Bool? = nil) {
        self.app = app
        self.text = text
        self.element_index = element_index
        self.background = background
    }
}

public struct ScrollInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let direction: String       // "up" | "down" | "left" | "right"
    public let pages: Double
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String, element_index: Int, direction: String, pages: Double, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.direction = direction
        self.pages = pages
        self.background = background
    }
}

public struct SetValueInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let value: String
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String, element_index: Int, value: String, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.value = value
        self.background = background
    }
}

public struct DragInput: Codable, Equatable {
    /// Required for window-coordinate drags; optional with display_id (the app
    /// under the start point is hit-tested, frontmost as fallback).
    public let app: String?
    public let from_x: Double
    public let from_y: Double
    public let to_x: Double
    public let to_y: Double
    /// When set, coordinates are pixels of the latest `screenshot` of this display.
    public let display_id: Int?
    public let mouse_button: String?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, from_x: Double, from_y: Double, to_x: Double, to_y: Double,
                display_id: Int? = nil, mouse_button: String? = nil, background: Bool? = nil) {
        self.app = app
        self.from_x = from_x
        self.from_y = from_y
        self.to_x = to_x
        self.to_y = to_y
        self.display_id = display_id
        self.mouse_button = mouse_button
        self.background = background
    }
}

public struct PerformSecondaryActionInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let action: String          // AX action name, e.g. "AXShowMenu"
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String, element_index: Int, action: String, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.action = action
        self.background = background
    }
}

public struct SelectTextInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let text: String
    public let prefix: String?
    public let suffix: String?
    public let selection_type: String  // "select" | "cursor_before" | "cursor_after"
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String, element_index: Int, text: String, prefix: String? = nil,
                suffix: String? = nil, selection_type: String, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.selection_type = selection_type
        self.background = background
    }
}
