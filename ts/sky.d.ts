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
}
export interface ListWindowsResult {
    windows: WindowInfo[];
}
export interface ListWindowsInput {
    app: AppIdentifier;
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
    /** Target a specific window (id from list_windows). Default: focused window. */
    window_id?: number;
    disableDiff?: boolean;
    include_data_url?: boolean;
}
export interface ClickInput {
    app: AppIdentifier;
    element_index?: number;
    /** Screenshot-pixel coordinates (see coordinate model). Coordinates are interpreted against — and the raise targets — the window of the latest get_app_state capture. */
    x?: number;
    y?: number;
    mouse_button?: MouseButton;
    click_count?: number;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface PressKeyInput {
    app: AppIdentifier;
    /** "+"-separated chord of X-keysym-style names, e.g. "Ctrl+Shift+t". */
    keys: string;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface TypeTextInput {
    app: AppIdentifier;
    text: string;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface ScrollInput {
    app: AppIdentifier;
    element_index: number;
    direction: Direction;
    pages: number;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface SetValueInput {
    app: AppIdentifier;
    element_index: number;
    value: string;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface DragInput {
    app: AppIdentifier;
    /** Screenshot-pixel coordinates (see coordinate model). Coordinates are interpreted against — and the raise targets — the window of the latest get_app_state capture. */
    from_x: number;
    from_y: number;
    to_x: number;
    to_y: number;
    mouse_button?: MouseButton;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface PerformSecondaryActionInput {
    app: AppIdentifier;
    element_index: number;
    /** AX action name, e.g. "AXShowMenu". */
    action: string;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
export interface SelectTextInput {
    app: AppIdentifier;
    element_index: number;
    text: string;
    prefix?: string;
    suffix?: string;
    selection_type: SelectTextSelectionType;
    /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
    background?: boolean;
}
import type { ActionResult, AppState, ClickInput, DragInput, GetAppStateInput, ListAppsInput, ListAppsResult, ListWindowsInput, ListWindowsResult, PerformSecondaryActionInput, PressKeyInput, ScrollInput, SelectTextInput, SetValueInput, TypeTextInput } from "./types.js";
export interface SkyConfig {
    socket_path: string;
    post_action_sleep_ms: number;
}
export declare function defaultConfig(): SkyConfig;
/** Reads JSON config from $SKYLIGHT_CONFIG_PATH over the defaults. */
export declare function loadConfig(): SkyConfig;
export declare function buildRequest(id: number, method: string, params: unknown): string;
export declare class SkyError extends Error {
    readonly code: string;
    constructor(code: string, message: string);
}
export declare class SkyClient {
    readonly config: SkyConfig;
    private socket;
    private connecting;
    private nextId;
    private buffer;
    private pending;
    constructor(config?: Partial<SkyConfig>);
    /** Lazy connect on first call, like @oai/sky. */
    private connect;
    /** Rejects and clears every pending call with the same error. */
    private rejectAllPending;
    /**
     * Called when the socket closes/ends/errors out from under us (including
     * the FIN the daemon sends right after an id:0 protocol error). Fails any
     * still-pending calls instead of leaving them hanging forever, and resets
     * connection state so the next call() reconnects lazily.
     */
    private handleSocketTeardown;
    private onData;
    call<T>(method: string, params: unknown): Promise<T>;
    close(): void;
    list_apps(input?: ListAppsInput): Promise<ListAppsResult>;
    list_windows(input: ListWindowsInput): Promise<ListWindowsResult>;
    get_app_state(input: GetAppStateInput): Promise<AppState>;
    click(input: ClickInput): Promise<ActionResult>;
    press_key(input: PressKeyInput): Promise<ActionResult>;
    type_text(input: TypeTextInput): Promise<ActionResult>;
    scroll(input: ScrollInput): Promise<ActionResult>;
    set_value(input: SetValueInput): Promise<ActionResult>;
    drag(input: DragInput): Promise<ActionResult>;
    perform_secondary_action(input: PerformSecondaryActionInput): Promise<ActionResult>;
    select_text(input: SelectTextInput): Promise<ActionResult>;
}
export * from "./types.js";
export { SkyClient, SkyError, defaultConfig, loadConfig, buildRequest } from "./client.js";
export type { SkyConfig } from "./client.js";
import { SkyClient } from "./client.js";
/** Shared lazy-connecting singleton, mirroring @oai/sky usage: `import { sky } from "@skylight/sky"`. */
export declare const sky: SkyClient;
