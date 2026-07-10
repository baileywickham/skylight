import Foundation

public struct AppInfo: Codable, Equatable {
    public let name: String
    public let bundle_id: String?
    public let pid: Int32
    public let is_frontmost: Bool
    public let launch_date: String?
    public init(name: String, bundle_id: String?, pid: Int32, is_frontmost: Bool, launch_date: String?) {
        self.name = name
        self.bundle_id = bundle_id
        self.pid = pid
        self.is_frontmost = is_frontmost
        self.launch_date = launch_date
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
    public init(window_id: Int?, title: String?, is_focused: Bool, is_minimized: Bool) {
        self.window_id = window_id
        self.title = title
        self.is_focused = is_focused
        self.is_minimized = is_minimized
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
    public init(url: String, data_url: String?, width: Int, height: Int) {
        self.url = url
        self.data_url = data_url
        self.width = width
        self.height = height
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
    public init(app: String, window_id: Int? = nil, disableDiff: Bool? = nil, include_data_url: Bool? = nil) {
        self.app = app
        self.window_id = window_id
        self.disableDiff = disableDiff
        self.include_data_url = include_data_url
    }
}

public struct ClickInput: Codable, Equatable {
    public let app: String
    public let element_index: Int?
    public let x: Double?
    public let y: Double?
    public let mouse_button: String?   // "left" | "right" | "middle"
    public let click_count: Int?
    public init(app: String, element_index: Int? = nil, x: Double? = nil, y: Double? = nil,
                mouse_button: String? = nil, click_count: Int? = nil) {
        self.app = app
        self.element_index = element_index
        self.x = x
        self.y = y
        self.mouse_button = mouse_button
        self.click_count = click_count
    }
}

public struct PressKeyInput: Codable, Equatable {
    public let app: String
    public let keys: String            // "+"-separated chord, e.g. "Ctrl+Shift+t"
    public init(app: String, keys: String) { self.app = app; self.keys = keys }
}

public struct TypeTextInput: Codable, Equatable {
    public let app: String
    public let text: String
    public init(app: String, text: String) { self.app = app; self.text = text }
}

public struct ScrollInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let direction: String       // "up" | "down" | "left" | "right"
    public let pages: Double
    public init(app: String, element_index: Int, direction: String, pages: Double) {
        self.app = app
        self.element_index = element_index
        self.direction = direction
        self.pages = pages
    }
}

public struct SetValueInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let value: String
    public init(app: String, element_index: Int, value: String) {
        self.app = app
        self.element_index = element_index
        self.value = value
    }
}

public struct DragInput: Codable, Equatable {
    public let app: String
    public let from_x: Double
    public let from_y: Double
    public let to_x: Double
    public let to_y: Double
    public let mouse_button: String?
    public init(app: String, from_x: Double, from_y: Double, to_x: Double, to_y: Double, mouse_button: String? = nil) {
        self.app = app
        self.from_x = from_x
        self.from_y = from_y
        self.to_x = to_x
        self.to_y = to_y
        self.mouse_button = mouse_button
    }
}

public struct PerformSecondaryActionInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let action: String          // AX action name, e.g. "AXShowMenu"
    public init(app: String, element_index: Int, action: String) {
        self.app = app
        self.element_index = element_index
        self.action = action
    }
}

public struct SelectTextInput: Codable, Equatable {
    public let app: String
    public let element_index: Int
    public let text: String
    public let prefix: String?
    public let suffix: String?
    public let selection_type: String  // "select" | "cursor_before" | "cursor_after"
    public init(app: String, element_index: Int, text: String, prefix: String? = nil,
                suffix: String? = nil, selection_type: String) {
        self.app = app
        self.element_index = element_index
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.selection_type = selection_type
    }
}
