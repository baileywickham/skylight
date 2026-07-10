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
}

export interface ListAppsResult {
  apps: AppInfo[];
}

export interface Screenshot {
  /** file:// path to the PNG under the daemon's shots dir ($SKYLIGHT_SHOTS_DIR). */
  url: string;
  /** base64 data URL — absent from the wire unless include_data_url: true was requested. */
  data_url?: string | null;
  width: number;
  height: number;
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
  disableDiff?: boolean;
  include_data_url?: boolean;
}

export interface ClickInput {
  app: AppIdentifier;
  element_index?: number;
  /** Screenshot-pixel coordinates (see coordinate model). */
  x?: number;
  y?: number;
  mouse_button?: MouseButton;
  click_count?: number;
}

export interface PressKeyInput {
  app: AppIdentifier;
  /** "+"-separated chord of X-keysym-style names, e.g. "Ctrl+Shift+t". */
  keys: string;
}

export interface TypeTextInput {
  app: AppIdentifier;
  text: string;
}

export interface ScrollInput {
  app: AppIdentifier;
  element_index: number;
  direction: Direction;
  pages: number;
}

export interface SetValueInput {
  app: AppIdentifier;
  element_index: number;
  value: string;
}

export interface DragInput {
  app: AppIdentifier;
  from_x: number;
  from_y: number;
  to_x: number;
  to_y: number;
  mouse_button?: MouseButton;
}

export interface PerformSecondaryActionInput {
  app: AppIdentifier;
  element_index: number;
  /** AX action name, e.g. "AXShowMenu". */
  action: string;
}

export interface SelectTextInput {
  app: AppIdentifier;
  element_index: number;
  text: string;
  prefix?: string;
  suffix?: string;
  selection_type: SelectTextSelectionType;
}
