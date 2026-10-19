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
    /// The target app's state right after the action, when the request asked
    /// for it with `return_state` (a diff against the last capture, like
    /// get_app_state). Saves the usual act-then-capture round trip.
    public let state: AppState?
    /// Set instead of `state` when the action succeeded but the follow-up
    /// capture failed — the action still happened.
    public let state_error: String?
    public init(done: Bool, state: AppState? = nil, state_error: String? = nil) {
        self.done = done
        self.state = state
        self.state_error = state_error
    }
}

/// The optional fields every action accepts on top of its own input. Decoded
/// separately from the action's params, so the per-action input types stay
/// about the action itself.
public struct PostActionParams: Codable, Equatable {
    public let app: String?
    /// Capture the app's tree after the action and return it in
    /// `ActionResult.state`. Needs `app`.
    public let return_state: Bool?
    /// With `return_state`: include the screenshot too (default false — the
    /// tree is usually enough to verify, and far cheaper).
    public let return_screenshot: Bool?
    public init(app: String? = nil, return_state: Bool? = nil, return_screenshot: Bool? = nil) {
        self.app = app
        self.return_state = return_state
        self.return_screenshot = return_screenshot
    }
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
    /// Modifier keys held during the press, "+"-separated like press_key's
    /// chord modifiers: "cmd", "shift", "cmd+shift", "alt", "ctrl". An AX
    /// press cannot carry modifiers, so an element_index click with modifiers
    /// becomes a pointer click at the element's visible center.
    public let modifiers: String?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, element_index: Int? = nil, x: Double? = nil, y: Double? = nil,
                display_id: Int? = nil, mouse_button: String? = nil, click_count: Int? = nil,
                hover: Bool? = nil, modifiers: String? = nil, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.x = x
        self.y = y
        self.display_id = display_id
        self.mouse_button = mouse_button
        self.click_count = click_count
        self.hover = hover
        self.modifiers = modifiers
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
    /// Required for window-coordinate and element drags; optional with
    /// display_id (the app under the start point is hit-tested, frontmost as
    /// fallback).
    public let app: String?
    /// Each end is either an element (from get_app_state — the pointer goes to
    /// its visible center) or an x/y point.
    public let from_element_index: Int?
    public let to_element_index: Int?
    public let from_x: Double?
    public let from_y: Double?
    public let to_x: Double?
    public let to_y: Double?
    /// When set, x/y are pixels of the latest `screenshot` of this display.
    public let display_id: Int?
    public let mouse_button: String?
    /// Modifier keys held for the whole drag, e.g. "alt" to copy in Finder.
    public let modifiers: String?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (`skylight background`).
    public let background: Bool?
    public init(app: String? = nil, from_element_index: Int? = nil, to_element_index: Int? = nil,
                from_x: Double? = nil, from_y: Double? = nil, to_x: Double? = nil, to_y: Double? = nil,
                display_id: Int? = nil, mouse_button: String? = nil, modifiers: String? = nil,
                background: Bool? = nil) {
        self.app = app
        self.from_element_index = from_element_index
        self.to_element_index = to_element_index
        self.from_x = from_x
        self.from_y = from_y
        self.to_x = to_x
        self.to_y = to_y
        self.display_id = display_id
        self.mouse_button = mouse_button
        self.modifiers = modifiers
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

// MARK: - Launching

public struct OpenAppInput: Codable, Equatable {
    /// App name ("Preview"), bundle id ("com.apple.Preview"), or the path of
    /// an .app bundle. Need not be running.
    public let app: String
    /// A URL or absolute file path to open with the app.
    public let url: String?
    /// Per-request background override: true launches without activating, so
    /// the user's frontmost app stays in front.
    public let background: Bool?
    public init(app: String, url: String? = nil, background: Bool? = nil) {
        self.app = app
        self.url = url
        self.background = background
    }
}

public struct OpenAppResult: Codable, Equatable {
    public let app: AppInfo
    /// false when the app was already running.
    public let launched: Bool
    public init(app: AppInfo, launched: Bool) {
        self.app = app
        self.launched = launched
    }
}

// MARK: - Finding and waiting

/// One element matched by `find` / `wait_for`. The index is live: act on it
/// directly, exactly like an index from get_app_state.
public struct FoundElement: Codable, Equatable {
    public let element_index: Int
    public let role: String
    public let title: String?
    public let value: String?
    /// The same line get_app_state would print for it.
    public let line: String
    /// The nearest labelled ancestors, outermost first ("AXGroup \"Sidebar\" >
    /// AXList"), to tell same-named matches apart.
    public let ancestors: String
    public init(element_index: Int, role: String, title: String?, value: String?, line: String, ancestors: String) {
        self.element_index = element_index
        self.role = role
        self.title = title
        self.value = value
        self.line = line
        self.ancestors = ancestors
    }
}

public struct FindInput: Codable, Equatable {
    public let app: String
    /// AX role, with or without the "AX" prefix ("button" = "AXButton").
    /// Case-insensitive.
    public let role: String?
    /// Case-insensitive substring of the element's label or value.
    public let text: String?
    /// Search this window (from list_windows). Default: the focused window.
    public let window_id: Int?
    /// Search only this element's subtree.
    public let root_element_index: Int?
    /// Default 50.
    public let max_results: Int?
    public let max_depth: Int?
    public let max_nodes: Int?
    public init(app: String, role: String? = nil, text: String? = nil, window_id: Int? = nil,
                root_element_index: Int? = nil, max_results: Int? = nil,
                max_depth: Int? = nil, max_nodes: Int? = nil) {
        self.app = app
        self.role = role
        self.text = text
        self.window_id = window_id
        self.root_element_index = root_element_index
        self.max_results = max_results
        self.max_depth = max_depth
        self.max_nodes = max_nodes
    }
}

public struct FindResult: Codable, Equatable {
    public let matches: [FoundElement]
    /// More elements matched than `max_results`.
    public let truncated: Bool
    public init(matches: [FoundElement], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

public struct WaitForInput: Codable, Equatable {
    public let app: String
    /// Element condition, as in `find`: at least one element matches.
    public let role: String?
    public let text: String?
    /// Window condition: some window of the app has a title containing this
    /// (case-insensitive) — a new document window, a "Save" dialog.
    public let window_title: String?
    /// Invert the element/window condition: wait until nothing matches (a
    /// spinner went away, a sheet closed).
    public let gone: Bool?
    /// Also (or with no other condition, only) wait until the tree stops
    /// changing between two polls — an Electron view done loading.
    public let stable: Bool?
    /// Default 5000, capped at 25000.
    public let timeout_ms: Int?
    public let window_id: Int?
    public let root_element_index: Int?
    public init(app: String, role: String? = nil, text: String? = nil, window_title: String? = nil,
                gone: Bool? = nil, stable: Bool? = nil, timeout_ms: Int? = nil,
                window_id: Int? = nil, root_element_index: Int? = nil) {
        self.app = app
        self.role = role
        self.text = text
        self.window_title = window_title
        self.gone = gone
        self.stable = stable
        self.timeout_ms = timeout_ms
        self.window_id = window_id
        self.root_element_index = root_element_index
    }
}

public struct WaitForResult: Codable, Equatable {
    public let elapsed_ms: Int
    /// Elements matching the element condition when it was met (empty for
    /// `gone`, window-only, or stable-only waits).
    public let matches: [FoundElement]
    public init(elapsed_ms: Int, matches: [FoundElement]) {
        self.elapsed_ms = elapsed_ms
        self.matches = matches
    }
}

// MARK: - Menus

public struct MenuSelectInput: Codable, Equatable {
    public let app: String
    /// Menu titles from the menu bar down, e.g. ["File", "Export As…"].
    /// Case-insensitive; "..." matches "…".
    public let path: [String]
    public let background: Bool?
    public init(app: String, path: [String], background: Bool? = nil) {
        self.app = app
        self.path = path
        self.background = background
    }
}

// MARK: - Batch

public struct BatchStep: Codable, Equatable {
    public let method: String
    public let params: JSONValue?
    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct BatchInput: Codable, Equatable {
    /// Run in order, at most `maxBatchSteps`.
    public let steps: [BatchStep]
    /// Stop at the first failed step (default true). The remaining steps are
    /// not run and do not appear in the results.
    public let stop_on_error: Bool?
    public init(steps: [BatchStep], stop_on_error: Bool? = nil) {
        self.steps = steps
        self.stop_on_error = stop_on_error
    }
}

public struct BatchStepResult: Codable, Equatable {
    public let method: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: ErrorPayload?
    public init(method: String, ok: Bool, result: JSONValue?, error: ErrorPayload?) {
        self.method = method
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public struct BatchResult: Codable, Equatable {
    /// One per step that ran, in order.
    public let results: [BatchStepResult]
    /// True when every step ran and succeeded.
    public let completed: Bool
    /// Why the batch stopped early when it was not a failed step — it ran out
    /// of its time budget, and the remaining steps were never started.
    public let stopped_reason: String?
    public init(results: [BatchStepResult], completed: Bool, stopped_reason: String? = nil) {
        self.results = results
        self.completed = completed
        self.stopped_reason = stopped_reason
    }
}
