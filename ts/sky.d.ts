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
import type { ActionResult, AppState, ClickInput, DragInput, GetAppStateInput, ListAppsResult, PerformSecondaryActionInput, PressKeyInput, ScrollInput, SelectTextInput, SetValueInput, TypeTextInput } from "./types.js";
export interface SkyConfig {
    socket_path: string;
    post_action_sleep_ms: number;
    shots_dir: string;
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
    private onData;
    call<T>(method: string, params: unknown): Promise<T>;
    close(): void;
    list_apps(): Promise<ListAppsResult>;
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
