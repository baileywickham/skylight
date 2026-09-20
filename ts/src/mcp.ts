// Skylight as an MCP server (stdio). Every daemon method becomes a tool, so a
// client like Claude Code drives native macOS apps through tool calls instead
// of TypeScript drivers. Screenshots come back as image content, sized for
// the model (SKYLIGHT_MCP_MAX_DIMENSION, default 1568 px on the long side);
// coordinates the model reads off an image are pixels of THAT image, and the
// daemon keeps the matching geometry, so no client-side conversion exists.
//
// Run: `skylight-run --mcp` (ensures the daemon, then execs this file).
// Register: `claude mcp add --scope user skylight -- skylight-run --mcp`.
import { execFile } from "node:child_process";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { SkyClient, SkyError, neverReachedDaemon } from "./client.js";
import type { AppState, DisplayScreenshot, ZoomResult } from "./types.js";

const MAX_DIMENSION = Number(process.env.SKYLIGHT_MCP_MAX_DIMENSION ?? 1568);

const sky = new SkyClient();

type Content =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

function text(value: unknown): Content[] {
  return [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 1) }];
}

/** A data: URL as MCP image content; nothing when the daemon sent none. */
function image(dataUrl: string | null | undefined): Content[] {
  if (!dataUrl) return [];
  const comma = dataUrl.indexOf(",");
  return [{ type: "image", data: dataUrl.slice(comma + 1), mimeType: "image/png" }];
}

// The in-bundle `skylight` CLI, passed by skylight-run. A `brew upgrade` stops
// the daemon and the cask's postflight cannot register it again from inside
// Homebrew's install-step sandbox, so a server that outlives the upgrade starts
// the daemon itself instead of failing every call until it is restarted.
const cli = process.env.SKYLIGHT_CLI;
let starting: Promise<boolean> | null = null;

function startDaemon(): Promise<boolean> {
  if (!cli) return Promise.resolve(false);
  starting ??= new Promise<boolean>((resolve) => {
    // Output is captured, never inherited: stdout is this server's transport.
    execFile(cli, ["start"], { timeout: 30_000 }, (err) => {
      starting = null;
      resolve(!err);
    });
  });
  return starting;
}

async function run(body: () => Promise<Content[]>) {
  try {
    return { content: await body() };
  } catch (err) {
    let failure = err;
    // Retry only a call that never reached the daemon: nothing was sent, so
    // it cannot run twice.
    if (neverReachedDaemon(err) && (await startDaemon())) {
      try {
        return { content: await body() };
      } catch (retryErr) {
        failure = retryErr;
      }
    }
    const message = failure instanceof SkyError ? `${failure.code}: ${failure.message}` : String(failure);
    return { isError: true, content: [{ type: "text" as const, text: message }] };
  }
}

function appStateContent(state: AppState): Content[] {
  const shot = state.screenshot;
  const header = shot
    ? `screenshot ${shot.width}x${shot.height}px (${shot.url}); click/drag x,y are pixels of this image`
    : `no screenshot (${state.screenshot_error}); act by element_index`;
  return [...text(`${header}\n${state.diffed ? "[diff since last capture]\n" : ""}${state.text}`), ...image(shot?.data_url)];
}

function displayShotContent(shot: DisplayScreenshot): Content[] {
  const note = `display ${shot.display_id}: ${shot.width}x${shot.height}px, ${shot.scale} px/pt, origin (${shot.origin_x},${shot.origin_y}). click/drag with display_id=${shot.display_id} take pixels of this image.`;
  return [...text(note), ...image(shot.data_url)];
}

function zoomContent(shot: ZoomResult): Content[] {
  const of = shot.window_id != null ? `window ${shot.window_id}` : `display ${shot.display_id}`;
  const keep = shot.window_id != null
    ? "keep using the last get_app_state pixels for clicks."
    : "keep using the last screenshot's pixels for clicks.";
  const note = `zoom of ${of}: ${shot.width}x${shot.height}px at ${shot.scale} px/pt, top-left at global point (${shot.origin_x},${shot.origin_y}). Read-only: ${keep}`;
  return [...text(note), ...image(shot.data_url)];
}

const app = z.string().describe("App name (e.g. \"Notes\") or bundle id (e.g. \"com.apple.Notes\").");
const background = z.boolean().optional().describe(
  "Override the daemon default for this call. Actions already run in the background by default (app not raised, the user's focus and cursor untouched; see capabilities.background_default). Pass false only when the app must come to the front.",
);
const displayId = z.number().int().optional().describe("Display id from list_displays. Default: the main display.");

const server = new McpServer(
  { name: "skylight", version: "0.3.0" },
  {
    instructions: [
      "Skylight drives native macOS apps. Preferred loop: get_app_state (indexed accessibility tree + screenshot) → act by element_index → get_app_state again to verify.",
      "For anything without a usable accessibility tree, or to see the whole desktop: screenshot → click/drag with display_id and the pixel coordinates you read off that image → zoom to read small text.",
      "Coordinates are ALWAYS pixels of the most recent image of that target (window capture per app, screenshot per display); the daemon converts them; zoom takes the same pixels (pass app for a window, display_id for a display).",
      "A control a web UI only renders on hover has no element_index until you hover it: call hover (element_index or x/y), then get_app_state again, then click it.",
      "Actions run in the background by default: the target app is not raised and the user's focus and cursor are untouched, so they can keep working. Actions on different apps run in parallel. Pass background: false only when the app must come to the front.",
      "Apps may be gated by an allowlist (approval_required): tell the user to run `skylight approve \"<App>\"`.",
    ].join("\n"),
  },
);

server.registerTool("capabilities", {
  description: "What this daemon can do on this Mac: TCC grants, private-symbol availability (focus without raise, Spaces), background mode and its effective default, parallel actuation.",
  annotations: { readOnlyHint: true },
}, () => run(async () => text(await sky.capabilities())));

server.registerTool("list_apps", {
  description: "Running apps that can be targeted. Regular (Dock) apps by default; include_menu_bar_apps adds status-item apps, tagged menu_bar_only.",
  inputSchema: { include_menu_bar_apps: z.boolean().optional() },
  annotations: { readOnlyHint: true },
}, (input) => run(async () => text(await sky.list_apps(input))));

server.registerTool("list_windows", {
  description: "An app's windows: window_id (for get_app_state/bring_to_active_space), title, is_focused, is_minimized, is_on_active_space.",
  inputSchema: { app },
  annotations: { readOnlyHint: true },
}, (input) => run(async () => text(await sky.list_windows(input))));

server.registerTool("get_app_state", {
  description: "Capture an app window: indexed accessibility tree ([n] AXRole \"label\" …) plus a screenshot image. Element indices are stable across captures and are the preferred way to act. Captures after the first return a diff unless disable_diff. First capture of a Chromium/Electron app can take ~3s; re-capture once if the tree looks empty.",
  inputSchema: {
    app,
    window_id: z.number().int().optional().describe("Target a specific window (from list_windows). Default: focused window."),
    disable_diff: z.boolean().optional().describe("Return the full tree instead of a diff."),
    max_dimension: z.number().int().optional().describe(`Longest side of the screenshot in px. Default ${MAX_DIMENSION}.`),
    include_screenshot: z.boolean().optional().describe("Default true. false returns only the tree (faster, cheaper)."),
    max_depth: z.number().int().positive().optional().describe("Tree depth budget, default 60. Raise it (e.g. 120) when the tree truncates with \"max depth … reached\" over the part you need — deep Chromium/Electron web content is the usual cause."),
    max_nodes: z.number().int().positive().optional().describe("Node budget, default 5000."),
    root_element_index: z.number().int().optional()
      .describe("Capture only this element's subtree (an index from an earlier capture) instead of the whole window — use it to work in one pane of an Electron app without an unrelated webview flooding the diff. Screenshot and click coordinates still cover the whole window."),
  },
  annotations: { readOnlyHint: true },
}, (input) => run(async () => {
  const state = await sky.get_app_state({
    app: input.app,
    window_id: input.window_id,
    disableDiff: input.disable_diff,
    root_element_index: input.root_element_index,
    include_data_url: input.include_screenshot ?? true,
    max_dimension: input.max_dimension ?? MAX_DIMENSION,
    max_depth: input.max_depth,
    max_nodes: input.max_nodes,
  });
  return appStateContent(state);
}));

server.registerTool("click", {
  description: "Click. Either element_index (from get_app_state, preferred — an AX press, works without focus in any app), or x/y pixels of the latest get_app_state screenshot of `app`, or x/y pixels of the latest `screenshot` when display_id is given (then app is optional: the app under the point is used). Coordinate clicks in the background only reach Chromium/Electron apps; in other apps they fail background_unavailable, so use element_index or background: false.",
  inputSchema: {
    app: app.optional(),
    element_index: z.number().int().optional(),
    x: z.number().optional(),
    y: z.number().optional(),
    display_id: z.number().int().optional().describe("Interpret x/y as pixels of the latest screenshot of this display."),
    mouse_button: z.enum(["left", "right", "middle"]).optional(),
    click_count: z.number().int().min(1).optional().describe("2 = double-click, 3 = triple."),
    hover: z.boolean().optional().describe("Move the pointer onto the point first. Default true (coordinate clicks only) — a click with no preceding move never reveals hover-only controls."),
    background,
  },
}, (input) => run(async () => text(await sky.click(input))));

server.registerTool("hover", {
  description: "Park the pointer over an element or point WITHOUT clicking, then re-capture get_app_state: this is how you reach a control that a web UI only renders on hover (row actions, \"⋯\" menus, tooltips). Background mode posts the move into the app, so the user's real cursor never moves. Same targeting as click: element_index, x/y of the latest get_app_state image, or x/y of the latest screenshot with display_id. Reaches the app's key window only (is_focused in list_windows) — a hover into another window of the same app is dropped; raise that window first.",
  inputSchema: {
    app: app.optional(),
    element_index: z.number().int().optional(),
    x: z.number().optional(),
    y: z.number().optional(),
    display_id: z.number().int().optional().describe("Interpret x/y as pixels of the latest screenshot of this display."),
    settle_ms: z.number().int().optional().describe("Hold the pointer there this long before returning. Default 250."),
    background,
  },
}, (input) => run(async () => text(await sky.hover(input))));

server.registerTool("press_key", {
  description: "Press a key chord: \"+\"-separated X-keysym names, e.g. \"Return\", \"Cmd+s\", \"Ctrl+Shift+Tab\", \"Escape\". Defaults to the frontmost app. Use repeat to send it N times in one call.",
  inputSchema: {
    app: app.optional(),
    keys: z.string(),
    repeat: z.number().int().positive().optional()
      .describe("Send the chord this many times (default 1, capped at 200). A chord cannot express repetition, so this is how you delete 20 characters in one call."),
    background,
  },
}, (input) => run(async () => text(await sky.press_key(input))));

server.registerTool("type_text", {
  description: "Type text. Pass element_index (with app) to focus that field first — without it the text goes wherever focus happens to be, which may be another field or nowhere. Apps may autocorrect; verify by re-capturing.",
  inputSchema: {
    app: app.optional(),
    text: z.string(),
    element_index: z.number().int().optional()
      .describe("Focus this element (from get_app_state) before typing; needs app. Errors if the element will not take focus, instead of typing into the wrong place."),
    background,
  },
}, (input) => run(async () => text(await sky.type_text(input))));

server.registerTool("scroll", {
  description: "Scroll an element from get_app_state by pages of its visible size. Needs background: false (which activates the app): a scroll wheel cannot be delivered to a background app.",
  inputSchema: {
    app,
    element_index: z.number().int(),
    direction: z.enum(["up", "down", "left", "right"]),
    pages: z.number().optional().describe("Default 1."),
    background,
  },
}, (input) => run(async () => text(await sky.scroll({ ...input, pages: input.pages ?? 1 }))));

server.registerTool("set_value", {
  description: "Set an element's AX value directly (text fields, sliders, checkboxes) without keystrokes. Verified: if the app accepts the write and keeps its old value (a controlled web input), this errors instead of reporting success.",
  inputSchema: { app, element_index: z.number().int(), value: z.string(), background },
}, (input) => run(async () => text(await sky.set_value(input))));

server.registerTool("drag", {
  description: "Drag from one point to another. Pixels of the latest get_app_state screenshot of `app`, or of the latest `screenshot` when display_id is given (app then optional). Like click, a background drag only reaches Chromium/Electron apps.",
  inputSchema: {
    app: app.optional(),
    from_x: z.number(), from_y: z.number(), to_x: z.number(), to_y: z.number(),
    display_id: z.number().int().optional(),
    mouse_button: z.enum(["left", "right", "middle"]).optional(),
    background,
  },
}, (input) => run(async () => text(await sky.drag(input))));

server.registerTool("perform_secondary_action", {
  description: "Perform a named AX action on an element, e.g. \"AXShowMenu\" for a context menu (use this instead of right-click in Chromium apps).",
  inputSchema: { app, element_index: z.number().int(), action: z.string(), background },
}, (input) => run(async () => text(await sky.perform_secondary_action(input))));

server.registerTool("select_text", {
  description: "Select text inside a text element, or place the caret before/after a match; prefix/suffix disambiguate repeated matches.",
  inputSchema: {
    app,
    element_index: z.number().int(),
    text: z.string(),
    prefix: z.string().optional(),
    suffix: z.string().optional(),
    selection_type: z.enum(["select", "cursor_before", "cursor_after"]).optional().describe("Default select."),
    background,
  },
}, (input) => run(async () => text(await sky.select_text({ ...input, selection_type: input.selection_type ?? "select" }))));

server.registerTool("list_displays", {
  description: "Attached displays: display_id, size in points, global origin, backing scale, is_main.",
  annotations: { readOnlyHint: true },
}, () => run(async () => text(await sky.list_displays())));

server.registerTool("screenshot", {
  description: "Screenshot a whole display (the pixel-based path, for content without an accessibility tree or to see the desktop). Coordinates read off this image go to click/drag with the same display_id.",
  inputSchema: {
    display_id: displayId,
    max_dimension: z.number().int().optional().describe(`Longest side in px. Default ${MAX_DIMENSION}.`),
    show_cursor: z.boolean().optional().describe("Default true."),
  },
  annotations: { readOnlyHint: true },
}, (input) => run(async () => displayShotContent(
  await sky.screenshot({ ...input, max_dimension: input.max_dimension ?? MAX_DIMENSION, include_data_url: true }),
)));

server.registerTool("zoom", {
  description: "Native-resolution crop to read small text. With `app`, the region is pixels of that app's latest get_app_state image (the same coordinates click takes) and the crop comes from that window — use this after get_app_state. Without `app`, it is pixels of the latest `screenshot` of a display. Read-only: it does not change what click coordinates mean.",
  inputSchema: {
    app: app.optional().describe("Crop this app's window, in pixels of its latest get_app_state image, instead of a display."),
    window_id: z.number().int().optional().describe("With app: a specific window. Default: the one the latest capture targeted."),
    display_id: displayId,
    x: z.number(), y: z.number(), width: z.number().positive(), height: z.number().positive(),
    max_dimension: z.number().int().optional().describe(`Longest side in px. Default ${MAX_DIMENSION}.`),
  },
  annotations: { readOnlyHint: true },
}, (input) => run(async () => zoomContent(
  await sky.zoom({ ...input, max_dimension: input.max_dimension ?? MAX_DIMENSION, include_data_url: true }),
)));

server.registerTool("read_clipboard", {
  description: "Read the clipboard: plain text if any, plus the pasteboard types present.",
  annotations: { readOnlyHint: true },
}, () => run(async () => text(await sky.read_clipboard())));

server.registerTool("write_clipboard", {
  description: "Replace the clipboard with plain text (then press_key Cmd+v to paste — far more reliable than type_text for long or non-ASCII text).",
  inputSchema: { text: z.string() },
}, (input) => run(async () => text(await sky.write_clipboard(input))));

server.registerTool("bring_to_active_space", {
  description: "Move an app's window onto the Space the user is looking at without switching Spaces (for windows list_windows reports as is_on_active_space: false).",
  inputSchema: { app, window_id: z.number().int().optional() },
}, (input) => run(async () => text(await sky.bring_to_active_space(input))));

const transport = new StdioServerTransport();
const shutdown = () => {
  sky.close();
  process.exit(0);
};
transport.onclose = shutdown;
// The SDK transport does not treat stdin EOF as close; without this the
// server would outlive the client that spawned it.
process.stdin.on("end", shutdown);
await server.connect(transport);
