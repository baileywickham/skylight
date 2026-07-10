export type AppIdentifier = string;
export type MouseButton = "left" | "right" | "middle";
export type Direction = "up" | "down" | "left" | "right";
export type SelectTextSelectionType = "select" | "cursor_before" | "cursor_after";

export interface AppInfo {
  name: string;
  bundle_id: string | null;
  pid: number;
  is_frontmost: boolean;
  launch_date: string | null;
}

export interface ListAppsResult {
  apps: AppInfo[];
}

export interface Screenshot {
  /** file:// path to the PNG under shots_dir (default delivery). */
  url: string;
  /** base64 data URL — present only when include_data_url: true was requested. */
  data_url?: string;
  width: number;
  height: number;
}

export interface AppState {
  /** Indexed accessibility text: full tree, or a diff when diffed is true (M2). */
  text: string;
  screenshot: Screenshot;
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
