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

Packaged as a signed `.app` with `LSUIElement=true` and a fixed bundle
identifier, run as a background agent. It is launched via a launchd
LaunchAgent (or `open -a`), **never** as a child process of the terminal —
otherwise TCC may attribute permission checks to the "responsible process"
(the terminal app) instead of SkylightService. See "Permissions & safety" for
the signing-identity requirements that make TCC grants survive rebuilds.

- **IPC server** — listens on the Unix socket. Protocol: one JSON object per
  line (request), one JSON object per line (response). Request:
  `{ "id": <n>, "method": "<name>", "params": { … } }`. Response:
  `{ "id": <n>, "ok": true, "result": { … } }` or
  `{ "id": <n>, "ok": false, "error": { "code": "<slug>", "message": "…" } }`.
  - **Global actuation serialization.** The daemon executes all actuation
    (and state capture) through a single serial queue, across *all* socket
    connections — not per-connection. Orphaned `tsx` scripts (e.g. from a
    Bash-tool timeout that killed the shell but not the script) would
    otherwise interleave `CGEvent` streams with a newer script's, producing
    garbage input. Requests from any connection queue behind the in-flight
    action.
  - **Socket hygiene.** The socket file is created mode `0600` (owner-only —
    it grants full input control of the session). On start, a stale socket
    from a previous crash is detected (connect fails) and unlinked before
    re-binding.
  - **Limits.** Each request has a per-request timeout (configurable; default
    ~30s, covering slow captures) after which the daemon responds with a
    timeout error rather than hanging the line. Requests are expected to fit
    a bounded line size (e.g. 1 MiB); oversized lines are rejected with a
    protocol error. Responses can be large only when the inline data-URL
    screenshot is explicitly requested (see below).
- **AppRegistry** — implements `list_apps` using `NSWorkspace`
  (running apps, bundle ids, display names) plus last-used/use-count metadata
  where available. Resolves an `AppIdentifier` (id, display name, or process
  name) to a running app + its focused window.
- **AXCapture** — walks the target app's focused-window `AXUIElement` tree,
  assigns integer `element_index` values, and serializes to the "accessibility
  text" format (indented, indexed, role + title/value per node). Maintains the
  previous capture per app and returns a **diff** by default; `disableDiff:true`
  returns the full tree.
  - **Sticky indices.** Indices are stable per element *across* captures, not
    reassigned per capture. `AXUIElement` refs for the same underlying element
    compare equal (`CFEqual`) and hash consistently (`CFHash`), so AXCapture
    keeps a persistent element→index map per app for the lifetime of the
    session: an element seen before keeps its index, new elements get fresh
    indices, and indices are never reused. This is what makes diffing
    coherent — a diff shows only changed/added/removed nodes, but their
    indices stay stable, so the model can reconcile the diff against its
    mental picture of the tree. The same map resolves an `element_index` back
    to the live `AXUIElement` for action calls (`click`, `set_value`, etc.).
  - **Messaging timeout.** AXCapture sets
    `AXUIElementSetMessagingTimeout` on the app element (a sub-second value,
    e.g. 250ms) so a hung or busy target app degrades to truncated output
    rather than blocking the daemon for the 6-second default per AX call.
  - **Chromium/Electron enablement.** Chrome, Slack, VS Code, and other
    Chromium/Electron apps expose an essentially empty AX tree until an
    assistive client sets `AXManualAccessibility` (Electron) or
    `AXEnhancedUserInterface` (Chromium) to true on the app's AX element.
    These are among the highest-value targets, so AXCapture sets these
    attributes on first capture of such an app and re-walks after a short
    settle delay.
  - **Tree size caps.** Capture is bounded by a max depth and max node count
    (configurable; e.g. depth 30 / 5,000 nodes). Subtrees cut off by either
    cap are marked with an explicit truncation node in the serialized text,
    so the model knows content exists below. Without caps, `get_app_state`
    on a large web page or IDE emits megabytes.
- **Screenshotter** — ScreenCaptureKit capture of the resolved window → PNG,
  cropped to the window (see "Coordinate model").
  - **AX-window → SCWindow bridge.** ScreenCaptureKit addresses windows by
    `CGWindowID`, but the resolver produces an `AXUIElement` window. The
    bridge is the private `_AXUIElementGetWindow(AXUIElement, CGWindowID*)`
    symbol from ApplicationServices — private API is an accepted trade-off
    for a personal tool, and it is the only exact mapping. Fallback (if the
    symbol ever disappears): match the AX window's frame + title against
    `SCShareableContent` windows for the same PID, which is fragile with
    duplicate titles/frames and is treated as best-effort only.
  - **Minimized / other-Space windows.** SCK cannot capture a minimized
    window. If the resolved window is minimized, the daemon auto-unminimizes
    it (sets `kAXMinimizedAttribute` to false) and waits briefly before
    capturing — consistent with the activation-first policy, since actions
    would need the window visible anyway. A window on another Space is
    handled by the same activation/raise step, which switches Spaces. If the
    window still cannot be captured, the request fails with
    `capture_failed` and a message naming the window state.
- **Actuator** — executes actions. Before any keyboard or coordinate action it
  activates and raises the resolved target window (see "App activation &
  focus" below); coordinate inputs are converted per the "Coordinate model"
  below.
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
    `selection_type` via `kAXSelectedTextRangeAttribute` (milestone 2; returns
    `not_implemented` in milestone 1).
  - Honors a configurable `post_action_sleep_ms` after successful actions
    (default 100ms, matching Sky) so the UI can repaint before the next capture.
- **Permissions** — on start, checks `AXIsProcessTrusted()` and screen-recording
  authorization; if missing, logs precise instructions for what to grant in
  System Settings and where.

#### App activation & focus

`CGEvent`-synthesized keyboard events and coordinate clicks are delivered to
the **frontmost** app — and when Claude runs `tsx script.ts` from the Bash
tool, the frontmost app is the terminal running Claude Code, not the target.
So before any keyboard action (`press_key`, `type_text`) or coordinate action
(coordinate `click`, `drag`), the Actuator MUST:

1. Activate the target app (`NSRunningApplication.activate(options:)`), and
2. Raise the resolved AX window (`AXUIElementPerformAction(kAXRaiseAction)` /
   set `kAXMainAttribute`), then wait for activation to take effect before
   posting events.

The alternative — `CGEventPostToPid` to deliver events to a background app
without activating it — is noted but not the default: many apps (notably
Chromium-based ones and apps that check `NSApp.isActive`) mishandle input
they receive while inactive, so activation-first is the reliable path.
Element-index actions that go through AX actions (`kAXPressAction`,
`set_value`, `perform_secondary_action`) do not strictly require activation,
but the Actuator activates for those too so post-action screenshots show the
window unobscured.

#### Coordinate model

Sky's contract is that `click`/`drag` coordinates are "in the app-window
screenshot" — i.e. **pixels of the returned PNG**. Skylight adopts the same
contract explicitly, because three coordinate spaces are in play:

- **Screenshot pixels** — ScreenCaptureKit returns backing-store pixels, so on
  Retina displays the PNG is 2x the window's point size. The screenshot is
  cropped to the target window, so `(0,0)` is the window's top-left.
- **Global points** — `CGEvent` mouse positions and AX element positions
  (`kAXPositionAttribute`) are in global screen coordinates, in points.
- **Window origin** — the resolved window's frame origin, in global points.

All coordinate inputs (`click`, `drag`) are interpreted as screenshot pixels.
The daemon converts before posting a `CGEvent`:

```
global_point = (screenshot_px / window_backing_scale_factor) + window_origin_points
```

where the backing scale factor comes from the display the window is on
(`NSScreen.backingScaleFactor` for the window's screen). The daemon records
the window frame and scale factor at capture time alongside the index map, so
a coordinate given against the latest screenshot converts against the same
geometry that produced it.

### 2. @skylight/sky (TypeScript)

- A `SkyClient` class exposing exactly the `WindowComputerUseClient` methods and
  the matching input/output types from the reference doc.
- Connects lazily on first call (like `@oai/sky`), over the Unix socket.
- Reads a JSON config (path from an env var, e.g. `SKYLIGHT_CONFIG_PATH`):
  `{ socket_path, post_action_sleep_ms, shots_dir }`.
- Serializes each method call to a socket request and awaits the response.
- Ships `sky.d.ts` type declarations the model can read.

### 3. CLI / bootstrap

- `skylight start` — launch/verify the daemon and socket (registers/boots the
  LaunchAgent or uses `open -a`, per the TCC launch-context rule above; never
  spawns the daemon as a terminal child).
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
Skylight instead **writes each screenshot PNG to disk** (under a per-run
`./.skylight/shots/` directory) and returns `screenshot.url` as a `file://`
path by default; Claude then views it with its Read tool. The inline data URL
is **opt-in** (e.g. `include_data_url: true` on `get_app_state`) — a
base64-encoded Retina window PNG is a multi-megabyte JSON line, which would
bloat every response and stdout capture for a payload the harness normally
never reads inline. This is the single intentional divergence from the
reference API.

## Error handling

- Every action returns a structured error (`{ code, message }`) rather than
  throwing opaque failures. Codes include: `app_not_found`,
  `no_focused_window`, `stale_element_index` (index unknown, or its element
  has disappeared from the tree), `element_not_actionable` (element exists in
  the latest capture but is dead or no longer supports the action),
  `permission_denied` (AX or screen recording not granted), `capture_failed`,
  `not_implemented` (e.g. `select_text` in milestone 1).
- The staleness model follows from sticky indices (see AXCapture): an index
  never silently re-points at a different element, but it can go bad in two
  ways. (1) The index is unknown or was last seen in an older capture whose
  element has since disappeared from the tree → `stale_element_index`.
  (2) The index is current in the latest capture but its backing
  `AXUIElement` is dead when acted on — the app returns
  `kAXErrorInvalidUIElement` — or the element has moved/changed such that the
  requested action no longer applies → `element_not_actionable`. Both are
  surfaced clearly so the model knows to re-run `get_app_state` and retry
  against fresh state.
- `permission_denied` includes the exact System Settings pane to open.
- The daemon logs every actuation (method + resolved target + result) to
  `~/Library/Logs/skylight/` for auditability and a manual kill switch
  (SIGTERM / a `SKYLIGHT_PAUSE` sentinel file halts actuation).

## Permissions & safety (v1)

- **Stable signing identity, not ad-hoc.** TCC identifies an app by its code
  signature's designated requirement. An ad-hoc signature has no identity —
  its designated requirement reduces to the cdhash, which changes on every
  rebuild, so an ad-hoc-signed daemon would lose its Accessibility and Screen
  Recording grants each time it is rebuilt. The service is therefore signed
  with a **stable identity** — a self-signed code-signing certificate created
  in Keychain Access, or an Apple Development certificate — together with a
  fixed bundle identifier, so the designated requirement (identifier +
  certificate anchor) stays constant across rebuilds and grants persist.
  First run walks the user through granting both once via `skylight doctor`.
- **Launch context matters for TCC.** The daemon must be launched via its
  launchd LaunchAgent or `open -a SkylightService` — not exec'd from a
  terminal — or TCC can attribute the grant to the responsible process
  (Terminal/iTerm) rather than the daemon, and the daemon's own checks fail.
- **Periodic re-prompts.** macOS 15+ (and 26) periodically re-prompts the
  user to re-approve apps that capture the screen; `skylight doctor` reports
  when the Screen Recording grant has lapsed so this is a diagnosed state,
  not a mystery `capture_failed`.
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

## Milestones

Scope stays as one plan, but delivery is cut into two milestones so the
riskiest plumbing (TCC, activation, coordinates, IPC) is proven end-to-end
before the subtler AX work:

- **Milestone 1 — end-to-end slice, diffing off.** All three layers wired up:
  daemon + socket + `@skylight/sky`, full window-API surface callable from
  Claude Code, screenshots, sticky-index capture and all actions — except that
  `get_app_state` behaves as if `disableDiff` is always true (full tree every
  time; the flag is accepted but a no-op), and `select_text` returns a
  structured `not_implemented` error.
- **Milestone 2 — diffing + select_text.** Tree diffing on top of the sticky
  element→index map (diff-by-default, `disableDiff` honored), and
  `select_text` implemented via `kAXSelectedTextRangeAttribute` (locate the
  match in the element's value, set the selection range or collapse it to a
  cursor per `selection_type`).

## Open questions / future work

- Windows/Linux targets (Sky has `window2` and `full-desktop` APIs) — out of
  scope for v1, but the library's client-per-platform structure leaves room.
- Lock-screen guardian and multi-session support if this grows past a personal
  tool.
