export type AppIdentifier = string;
export type MouseButton = "left" | "right" | "middle";
export type Direction = "up" | "down" | "left" | "right";
export type SelectTextSelectionType = "select" | "cursor_before" | "cursor_after";

export interface AppInfo {
  name: string;
  /** Absent on the wire when the app has no bundle id (Swift encodeIfPresent). */
  bundle_id?: string | null;
  pid: number;
  is_frontmost: boolean;
  /** Absent on the wire when unknown (Swift encodeIfPresent). */
  launch_date?: string | null;
  /** true for menu bar (LSUIElement/accessory) apps — a status item instead of windows. Absent for Dock apps. */
  menu_bar_only?: boolean | null;
}

export interface ListAppsInput {
  /** Also list menu bar (accessory) apps. Default false. */
  include_menu_bar_apps?: boolean;
}

export interface ListAppsResult {
  apps: AppInfo[];
}

export interface WindowInfo {
  /** CGWindowID; absent when the daemon's window-id bridge is unavailable. */
  window_id?: number | null;
  title?: string | null;
  is_focused: boolean;
  is_minimized: boolean;
  /** On the Space the user is looking at. Absent when the Spaces bridge is unavailable. */
  is_on_active_space?: boolean | null;
}

export interface ListWindowsResult {
  windows: WindowInfo[];
}

export interface ListWindowsInput {
  app: AppIdentifier;
}

export interface PermissionStatus {
  accessibility: boolean;
  screen_recording: boolean;
}

export interface SkyLightCapabilities {
  /**
   * Background actions can make an app AppKit-active without raising it, so
   * menu key equivalents (Cmd+c) fire in a non-frontmost app. False on a macOS
   * release where the private symbols are gone — background actions still work,
   * but revert to best-effort for keyboard/coordinate input.
   */
  focus_without_raise: boolean;
  /** Experimental SkyLight event channel; opt in with SKYLIGHT_TRUSTED_EVENTS=1. */
  trusted_events: boolean;
  /** Background mouse BUTTON events can be built (the private window-location stamp resolved). False → background click/drag are ignored by the target app; pass background: false. */
  background_mouse_events: boolean;
  /** Windows can be queried for / moved to the active Space (bring_to_active_space). */
  space_management: boolean;
}

export interface CapabilitiesResult {
  version: string;
  permissions: PermissionStatus;
  skylight: SkyLightCapabilities;
  /**
   * The configured default: "auto" (background wherever focus_without_raise is
   * available — the built-in default), "on", or "off". Set with
   * `skylight background on|off|auto`.
   */
  background_mode: "auto" | "on" | "off";
  /** What `background_mode` resolves to now: the effective value for an action that omits `background`. */
  background_default: boolean;
  /**
   * Actions against DIFFERENT apps may run concurrently. Requests for one app
   * are always serialized, and foreground actions always run alone.
   */
  parallel_actuation: boolean;
}

export interface Screenshot {
  /** file:// path to the PNG under the daemon's shots dir ($SKYLIGHT_SHOTS_DIR). */
  url: string;
  /** base64 data URL — absent from the wire unless include_data_url: true was requested. */
  data_url?: string | null;
  width: number;
  height: number;
  /** PNG pixels per screen point (lower than the backing scale when max_dimension shrank it). */
  scale?: number | null;
}

export interface DisplayInfo {
  /** CGDirectDisplayID — pass as display_id to screenshot/zoom/click/drag. */
  display_id: number;
  /** Size in points. */
  width: number;
  height: number;
  /** Global top-left origin in points (main display is 0,0). */
  origin_x: number;
  origin_y: number;
  /** 2 on Retina. */
  backing_scale: number;
  is_main: boolean;
  name?: string | null;
}

export interface ListDisplaysResult {
  displays: DisplayInfo[];
}

export interface ScreenshotInput {
  /** Default: the main display. */
  display_id?: number;
  /** Longest side in pixels; the image is downscaled to fit. Default: 1 px per point. */
  max_dimension?: number;
  include_data_url?: boolean;
  /** Draw the pointer. Default true. */
  show_cursor?: boolean;
}

/** A display or display-region capture. global_point = origin + px / scale. */
export interface DisplayScreenshot {
  display_id: number;
  /** file:// path to the PNG. */
  url: string;
  data_url?: string | null;
  width: number;
  height: number;
  /** PNG pixels per screen point. */
  scale: number;
  /** Global point of pixel (0,0). */
  origin_x: number;
  origin_y: number;
}

export interface ZoomInput {
  /** Zoom into this app's window instead of a display: the region is then pixels of its latest get_app_state capture, and the crop comes from a fresh capture of that window (so an occluded window still reads correctly). */
  app?: AppIdentifier;
  /** With app: a specific window (from list_windows). Default: the window the latest capture targeted. */
  window_id?: number;
  /** Without app: which display. Default: the main display. */
  display_id?: number;
  /** Region in pixels of the latest image of that target: the display's screenshot (points if there was none), or with app the get_app_state window capture. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** Longest side cap; default: native backing scale. */
  max_dimension?: number;
  include_data_url?: boolean;
}

/** A zoomed crop. Exactly one of display_id / window_id says what it came from. */
export interface ZoomResult {
  display_id?: number | null;
  window_id?: number | null;
  /** file:// path to the PNG. */
  url: string;
  data_url?: string | null;
  width: number;
  height: number;
  /** PNG pixels per screen point. */
  scale: number;
  /** Global point of pixel (0,0). */
  origin_x: number;
  origin_y: number;
}

export interface ClipboardResult {
  /** Absent when the pasteboard holds no string. */
  text?: string | null;
  /** UTIs on the pasteboard, so "empty" and "an image" are distinguishable. */
  types: string[];
  change_count: number;
}

export interface WriteClipboardInput {
  text: string;
}

export interface BringToActiveSpaceInput {
  app: AppIdentifier;
  /** Default: the app's focused window. */
  window_id?: number;
}

export interface BringToActiveSpaceResult {
  window_id: number;
  /** On the active Space after the call. */
  on_active_space: boolean;
  /** This call moved it (false when it was already there). */
  moved: boolean;
}

export interface AppState {
  /** Indexed accessibility text: full tree, or a diff when diffed is true (M2). */
  text: string;
  /** Absent when the screenshot failed but AX capture succeeded (AX-only degraded response). */
  screenshot?: Screenshot | null;
  /** Present exactly when screenshot is absent: "<code>: <message>". */
  screenshot_error?: string | null;
  diffed: boolean;
}

export interface ActionResult {
  done: boolean;
}

export interface GetAppStateInput {
  app: AppIdentifier;
  /** Target a specific window (id from list_windows). Default: focused window. */
  window_id?: number;
  disableDiff?: boolean;
  include_data_url?: boolean;
  /** Longest side of the screenshot in pixels; downscaled to fit. Click coordinates stay pixels of the returned image. */
  max_dimension?: number;
  /** Tree depth budget (default 60). Raise it when the tree truncates with a "max depth … reached" marker over the part you need — deep Chromium/Electron web content is the usual cause. */
  max_depth?: number;
  /** Node budget (default 5000). */
  max_nodes?: number;
  /** Serialize only this element's subtree (an index from an earlier capture) instead of the whole window — the pane you are working in, so another webview's churn stays out of the tree and the diff. The screenshot and click coordinates still describe the whole window. */
  root_element_index?: number;
}

export interface ClickInput {
  /** Required with element_index or window coordinates. Optional with display_id: the app under the point is hit-tested (frontmost as fallback). */
  app?: AppIdentifier;
  element_index?: number;
  /** Screenshot-pixel coordinates (see coordinate model). Without display_id they are interpreted against — and the raise targets — the window of the latest get_app_state capture; with display_id, against the latest screenshot of that display. */
  x?: number;
  y?: number;
  /** Interpret x/y as pixels of the latest `screenshot` of this display. */
  display_id?: number;
  mouse_button?: MouseButton;
  click_count?: number;
  /** Move the pointer onto the point before pressing (default true; coordinate clicks only — an element_index click is an AX press). Hover-only affordances never render without it. */
  hover?: boolean;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

/** Park the pointer over an element or point without clicking, so hover-only UI renders for the next capture. In background mode the user's real cursor never moves. Reaches the app's KEY window only — a hover into another window of the same app is dropped. */
export interface HoverInput {
  /** Required with element_index or window coordinates; optional with display_id. */
  app?: AppIdentifier;
  element_index?: number;
  x?: number;
  y?: number;
  /** Interpret x/y as pixels of the latest `screenshot` of this display. */
  display_id?: number;
  /** Hold the pointer there this long before returning. Default 250, capped at 5000. */
  settle_ms?: number;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface PressKeyInput {
  /** Default: the frontmost app. */
  app?: AppIdentifier;
  /** "+"-separated chord of X-keysym-style names, e.g. "Ctrl+Shift+t". */
  keys: string;
  /** Send the chord this many times (default 1, capped at 200) — one call instead of N round trips. A chord cannot express repetition ("BackSpace BackSpace" is not a chord). */
  repeat?: number;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface TypeTextInput {
  /** Default: the frontmost app. */
  app?: AppIdentifier;
  text: string;
  /** Focus this element first (needs `app`). Without it the text goes wherever focus happens to be — another field, or nowhere — and the call still reports success. With it, a field that will not take focus is an error. */
  element_index?: number;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface ScrollInput {
  app: AppIdentifier;
  element_index: number;
  direction: Direction;
  pages: number;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface SetValueInput {
  app: AppIdentifier;
  element_index: number;
  value: string;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface DragInput {
  /** Required for window coordinates; optional with display_id (hit-tested at the start point). */
  app?: AppIdentifier;
  /** Screenshot-pixel coordinates (see coordinate model): the latest get_app_state window capture, or with display_id the latest screenshot of that display. */
  from_x: number;
  from_y: number;
  to_x: number;
  to_y: number;
  /** Interpret coordinates as pixels of the latest `screenshot` of this display. */
  display_id?: number;
  mouse_button?: MouseButton;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface PerformSecondaryActionInput {
  app: AppIdentifier;
  element_index: number;
  /** AX action name, e.g. "AXShowMenu". */
  action: string;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}

export interface SelectTextInput {
  app: AppIdentifier;
  element_index: number;
  text: string;
  prefix?: string;
  suffix?: string;
  selection_type: SelectTextSelectionType;
  /** Per-request override. true = act without activating or raising the app; false = bring it frontmost first. Absent = daemon default (`capabilities().background_default`, normally true). */
  background?: boolean;
}
