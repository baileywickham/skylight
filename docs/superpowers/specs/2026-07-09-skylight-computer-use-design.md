# Skylight — a macOS computer-use agent for Claude

**Date:** 2026-07-09
**Status:** Approved design, pending implementation plan

## Summary

Skylight is a macOS computer-use agent that lets Claude see and control native
Mac apps. It is a close reconstruction of OpenAI's "Sky" / CUAService architecture
(the computer-use engine shipped inside the ChatGPT/Codex desktop app), adapted so
that **Claude Code is the harness** instead of OpenAI's embedded Chromium + Node
runtime.

The design is accessibility-tree-first: the agent captures a target app window's
`AXUIElement` tree (with numbered elements and diffing) alongside a screenshot,
and acts either on an indexed element (via an accessibility action) or on a raw
coordinate (via synthetic input). Claude drives it by writing TypeScript that
calls a `sky`-style library, run with `tsx` from the Claude Code Bash tool.

## Goals

- Faithfully reproduce Sky's three-layer architecture: a privileged native
  service that holds the OS permissions, a Unix-socket IPC boundary, and a thin
  model-facing library.
- Full parity with Sky's macOS window API surface (all methods below).
- Usable today from Claude Code with no product wrapper.

## Non-goals (v1)

- No cloud session syncing or remote hosting.
- No lock-screen guardian (Sky ships one; deferred as YAGNI).
- No standalone agent loop / self-contained CUA app — Claude Code is the harness.
- Single local user only.

## Reference: what we are copying

Derived by inspecting `/Applications/ChatGPT.app` (bundle id `com.openai.codex`).
Relevant facts:

- The computer-use engine is **Sky**, a background agent bundled at
  `Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app`,
  bundle id `com.openai.sky.CUAService`, `LSUIElement=true`.
- Sky links `ApplicationServices` (Accessibility / AX API), AppKit, Carbon,
  ScreenCaptureKit.
- The model calls a Node/TS package `@oai/sky` ("Model-facing computer use API").
  Calls are relayed via a native addon (`sky.node`) over a Unix socket
  (`.../IPC/computeruse.sock`) and NSXPC to the privileged `SkyComputerUseService`.
- The macOS API surface is documented inside the app at
  `docs/sky-window-api.md`. It is per-app-window and accessibility-tree-first.

The captured macOS API surface we are matching (`WindowComputerUseClient`):

| Method | Purpose |
| --- | --- |
| `list_apps()` | List targetable apps + running/last-used metadata. |
| `get_app_state(input)` | Screenshot + accessibility text for an app window; diffs from previous tree unless `disableDiff`. |
| `click(input)` | Click an indexed element from latest state, or a coordinate. |
| `press_key(input)` | Press a `+`-separated key chord (X keysym-style names). |
| `type_text(input)` | Type text into current focus. |
| `scroll(input)` | Scroll an indexed element. |
| `set_value(input)` | Replace value of an indexed editable element. |
| `drag(input)` | Drag from one app-window coordinate to another. |
| `perform_secondary_action(input)` | Invoke a named AX action on an indexed element. |
| `select_text(input)` | Select/position cursor at matching text in an editable element. |

Input/output types (`AppState`, `ClickInput`, `Screenshot`, `MouseButton`,
`Direction`, `SelectTextSelectionType`, etc.) mirror the doc verbatim, with one
deviation noted below (screenshot delivery).

## Architecture

Three layers, mirroring Sky:

```
Claude Code (harness)
  │  writes a .ts script, runs `tsx script.ts` via Bash
  ▼
@skylight/sky  (model-facing TypeScript library, ≙ @oai/sky)
  │  one JSON request per line
  ▼  Unix domain socket: ~/Library/Application Support/skylight/ipc/computeruse.sock
SkylightService  (privileged Swift daemon, ≙ CUAService)
     holds Accessibility + Screen Recording TCC grants
     AXUIElement tree walk · CGEvent input · ScreenCaptureKit capture
     background LSUIElement agent
```

The only structural difference from Sky is the top layer: Claude Code + `tsx`
replace OpenAI's embedded Chromium/Node runtime. The library → socket → native
service path is the same shape (we use a line-delimited JSON protocol over the
Unix socket rather than NSXPC, since there is no Apple-framework client on the
TS side).

## Components

### 1. SkylightService (Swift)

Packaged as a signed `.app` with `LSUIElement=true`, run as a background agent.

- **IPC server** — listens on the Unix socket. Protocol: one JSON object per
  line (request), one JSON object per line (response). Request:
  `{ "id": <n>, "method": "<name>", "params": { … } }`. Response:
  `{ "id": <n>, "ok": true, "result": { … } }` or
  `{ "id": <n>, "ok": false, "error": { "code": "<slug>", "message": "…" } }`.
- **AppRegistry** — implements `list_apps` using `NSWorkspace`
  (running apps, bundle ids, display names) plus last-used/use-count metadata
  where available. Resolves an `AppIdentifier` (id, display name, or process
  name) to a running app + its focused window.
- **AXCapture** — walks the target app's focused-window `AXUIElement` tree,
  assigns integer `element_index` values, and serializes to the "accessibility
  text" format (indented, indexed, role + title/value per node). Maintains the
  previous capture per app and returns a **diff** by default; `disableDiff:true`
  returns the full tree. Index→element mapping is cached so later action calls
  (`click`, `set_value`, etc.) can resolve an `element_index` to the live
  `AXUIElement`.
- **Screenshotter** — ScreenCaptureKit capture of the resolved window → PNG.
- **Actuator** — executes actions:
  - `click`: `element_index` → `AXUIElementPerformAction(kAXPressAction)` (or
    coordinate → `CGEvent` mouse down/up at window-relative point, honoring
    `mouse_button` and `click_count`).
  - `press_key`: parse the `+`-separated chord (keysym-style names + aliases
    Control/Ctrl/Alt/Shift), synthesize `CGEvent` key events.
  - `type_text`: synthesize Unicode key events into current focus.
  - `scroll`: scroll the indexed element by `pages` in `direction`.
  - `set_value`: `AXUIElementSetAttributeValue(kAXValueAttribute, …)`.
  - `drag`: `CGEvent` mouse drag from → to (window-relative).
  - `perform_secondary_action`: `AXUIElementPerformAction(<action name>)`.
  - `select_text`: locate text in the indexed editable element (with optional
    prefix/suffix disambiguation) and set selection or cursor per
    `selection_type`.
  - Honors a configurable `post_action_sleep_ms` after successful actions
    (default 100ms, matching Sky) so the UI can repaint before the next capture.
- **Permissions** — on start, checks `AXIsProcessTrusted()` and screen-recording
  authorization; if missing, logs precise instructions for what to grant in
  System Settings and where.

### 2. @skylight/sky (TypeScript)

- A `SkyClient` class exposing exactly the `WindowComputerUseClient` methods and
  the matching input/output types from the reference doc.
- Connects lazily on first call (like `@oai/sky`), over the Unix socket.
- Reads a JSON config (path from an env var, e.g. `SKYLIGHT_CONFIG_PATH`):
  `{ socket_path, post_action_sleep_ms, shots_dir }`.
- Serializes each method call to a socket request and awaits the response.
- Ships `sky.d.ts` type declarations the model can read.

### 3. CLI / bootstrap

- `skylight start` — launch/verify the daemon and socket.
- `skylight doctor` — report Accessibility + Screen Recording grant status and
  socket health.
- Emits `sky.d.ts` and a short usage note for the model.

## Data flow (one turn)

Claude writes and runs:

```ts
import { sky } from "@skylight/sky";
const state = await sky.get_app_state({ app: "Notes" });
// state.text     = indexed AX tree (inline in stdout)
// state.screenshot.url = file:// path under ./.skylight/shots/
await sky.click({ app: "Notes", element_index: 12 });
await sky.type_text({ app: "Notes", text: "hello" });
```

**Screenshot delivery — deliberate deviation from Sky.** Sky returns the
screenshot as a data URL only. Because the Claude Code harness is Bash-based,
Skylight also **writes each screenshot PNG to disk** (under a per-run
`./.skylight/shots/` directory) and returns `screenshot.url` as a `file://`
path; Claude then views it with its Read tool. The inline data URL remains
available for callers that want it. This is the single intentional divergence
from the reference API.

## Error handling

- Every action returns a structured error (`{ code, message }`) rather than
  throwing opaque failures. Codes include: `app_not_found`,
  `no_focused_window`, `stale_element_index` (index refers to a tree older than
  the latest `get_app_state`), `element_not_actionable`, `permission_denied`
  (AX or screen recording not granted), `capture_failed`.
- `stale_element_index` is surfaced clearly so the model knows to re-capture
  state before retrying — indices are only valid against the most recent
  `get_app_state` for that app.
- `permission_denied` includes the exact System Settings pane to open.
- The daemon logs every actuation (method + resolved target + result) to
  `~/Library/Logs/skylight/` for auditability and a manual kill switch
  (SIGTERM / a `SKYLIGHT_PAUSE` sentinel file halts actuation).

## Permissions & safety (v1)

- The service is code-signed (ad-hoc/self-signed acceptable for personal use) so
  its Accessibility + Screen Recording grants persist across rebuilds. First run
  walks the user through granting both once via `skylight doctor`.
- Kill switch: SIGTERM or a `SKYLIGHT_PAUSE` file; full actuation log.
- No lock-screen guardian in v1.

## Testing

- **Swift unit tests**: `AXCapture` serialization + diffing against a fixture AX
  tree; `element_index` → action resolution; key-chord parsing.
- **Integration smoke test**: drive a harmless system app (Calculator or
  TextEdit) — `get_app_state` → `click` a known element → assert the AX tree
  changed.
- **TS↔Swift contract test**: shared JSON fixtures assert the library's
  serialized requests and parsed responses match the service's schema, so the
  two layers cannot drift.

## Open questions / future work

- Windows/Linux targets (Sky has `window2` and `full-desktop` APIs) — out of
  scope for v1, but the library's client-per-platform structure leaves room.
- Lock-screen guardian and multi-session support if this grows past a personal
  tool.
