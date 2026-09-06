---
name: skylight
description: Use when asked to see, read, click, type into, or otherwise drive a native macOS app (computer use on this Mac — TextEdit, Finder, Messages, Notes, any app window), take a window screenshot with its accessibility tree, or when the user mentions Skylight or skylight-run.
---

# Skylight — driving native macOS apps

Skylight (installed via `brew install --cask skylight`; repo: `~/workspace/skylight`) is a local computer-use daemon: it captures an app window's accessibility (AX) tree + screenshot, and performs clicks/keys/typing on it. It also does the pixel-only path (whole-display screenshot, zoom, click at screen coordinates), clipboard, and Spaces. `skylight-run` (on PATH) wraps everything — daemon startup, module-format gotchas — so drivers work from any directory.

**If the `mcp__skylight__*` tools are available, use them** — same methods as below, screenshots arrive as images, no driver files. Drop to `skylight-run` drivers only for batch/parallel work that is awkward as one tool call at a time.

## Quick start

Inline (easiest — `sky` is pre-imported and auto-closed, top-level await OK):

```bash
skylight-run -e '
const s = await sky.get_app_state({ app: "TextEdit" });
console.log(s.text);                 // indexed AX tree: [3] AXButton "Save" ...
await sky.click({ app: "TextEdit", element_index: 3 });
await sky.type_text({ app: "TextEdit", text: "hello" });'
```

For longer drivers write a **`.mts` file** (never plain `.ts` outside the repo — CJS breaks top-level await; never `npx tsx -e`) importing:
`import { sky } from '<dir>/src/index.js'` where `<dir>` is `$(skylight-run --ts-dir)`
then `skylight-run driver.mts`. End with `sky.close()`.

Other commands: `skylight-run --status` (permissions/socket report), `skylight-run --stop`.

## Workflow

1. `get_app_state` → read the indexed AX tree (`s.text`) and/or screenshot (`s.screenshot?.url` — may be absent with `s.screenshot_error` set when Screen Recording is ungranted; the AX text still works).
2. Act by `element_index` (preferred — stable across captures) or screenshot-pixel `x`/`y`.
3. Re-capture to verify; repeat. Captures after the first return **diffs** by default; pass `disableDiff: true` for the full tree.

## API quick reference

All methods take `app` (app name, e.g. `"Finder"`). Full types: `$(skylight-run --ts-dir)/sky.d.ts`.

| Method | Key params |
|---|---|
| `list_apps` | `include_menu_bar_apps?` (also list accessory/LSUIElement apps, tagged `menu_bar_only`) |
| `list_windows` | — (windows with `window_id`, `title`, `is_focused`) |
| `get_app_state` | `disableDiff?`, `window_id?` (from `list_windows`), `include_data_url?` |
| `click` | `element_index` OR `x`,`y` (screenshot px); `display_id?` makes x/y pixels of the latest `screenshot` (then `app` is optional — hit-tested); `mouse_button?`, `click_count?` |
| `press_key` | `keys`: X-keysym chord, e.g. `"Cmd+s"`, `"Ctrl+Shift+t"`, `"Return"`; `app` optional (frontmost) |
| `type_text` | `text`; `app` optional (frontmost) |
| `scroll` | `element_index`, `direction` (up/down/left/right), `pages` |
| `set_value` | `element_index`, `value` |
| `drag` | `from_x`,`from_y`,`to_x`,`to_y` (screenshot px); `display_id?` as for click |
| `perform_secondary_action` | `element_index`, `action` (e.g. `"AXShowMenu"`) |
| `select_text` | `element_index`, `text`, `prefix?`, `suffix?`, `selection_type` |
| `capabilities` | — (TCC grants, private-symbol availability, `parallel_actuation`, `space_management`) |
| `list_displays` | — (`display_id`, size in points, origin, `backing_scale`, `is_main`) |
| `screenshot` | `display_id?`, `max_dimension?`, `show_cursor?`, `include_data_url?` — whole display, 1 px/pt by default |
| `zoom` | `display_id?`, `x`,`y`,`width`,`height` (px of the latest screenshot), `max_dimension?` — native-res crop, read-only |
| `read_clipboard` / `write_clipboard` | — / `text` |
| `bring_to_active_space` | `app`, `window_id?` — move a window to the current Space without switching |

Every action (`click`, `press_key`, `type_text`, `scroll`, `set_value`, `drag`, `perform_secondary_action`, `select_text`) also accepts `background?: true`.

## Pixel path (no AX tree, or the whole desktop)

```bash
skylight-run -e '
const shot = await sky.screenshot();            // 1 px per point; view shot.url with Read
const z = await sky.zoom({ x: 600, y: 300, width: 400, height: 200 });  // native-res detail
await sky.click({ x: 640, y: 350, display_id: shot.display_id });     // app hit-tested at the point
await sky.write_clipboard({ text: "long text" }); await sky.press_key({ keys: "Cmd+v" });'
```

Coordinates are always pixels of the most recent image of that target (per-app window capture, or per-display `screenshot`); `zoom` never changes them. `get_app_state` and `screenshot` take `max_dimension` to cap the long side.

## Per-app notes

- **Menu bar (status item) apps** (ArtWall, and any LSUIElement app): hidden from
  `list_apps` by default — pass `{ include_menu_bar_apps: true }` to see them, but
  `get_app_state`/actions accept their name directly either way. With no windows, the
  capture roots at a synthetic `AXMenuBarApp` node: the status item (click it to open
  the app's popover) plus the popover contents once open. Screenshots cover the open
  popover (the closed state usually degrades to AX-only). The popover TOGGLES on each
  status-item click and its state persists between calls — check the tree for
  `AXPopover` before clicking, or you'll close what you meant to open. If the app also
  opens a real window (e.g. Settings), captures switch to the normal window path.
- **Chrome / browsers**: the tab strip is NOT in the AX tree — the window title tells you the active tab; `list_windows` enumerates windows (per profile). For tab-level work prefer the claude-in-chrome browser tools; Skylight is for the native chrome (dialogs, menus, settings).
- **Chromium/Electron apps** (Slack, Obsidian, Notion, VS Code): first capture is slow (up to ~3s) while accessibility enablement settles; subsequent captures are fast. If the tree looks empty, re-capture once.
- **Finder**: the desktop belongs to Finder — its tree often starts with the desktop scroll area, not a window. Use `list_windows` + `window_id` to target an actual Finder window.
- **Multi-window apps**: `get_app_state` defaults to the focused window. When the user says "this window", check `list_windows` and pick by `is_focused` / title.

## Background & parallel work

`background: true` on any action drives the app **without raising it or moving the
user's cursor** — they keep working while you do. Menu shortcuts (`Cmd+s`) fire
correctly in background mode: the daemon makes the app AppKit-active without
raising the window.

Background actions against **different apps run in parallel**, so fan out with
`Promise.all` when the work is independent:

```ts
await Promise.all([
  sky.type_text({ app: "Notes", text: "draft", background: true }),
  sky.click({ app: "Safari", element_index: 12, background: true }),
]);
```

Rules:
- Two calls against the **same app** are serialized automatically — safe, just not faster.
- **Foreground** actions (the default) always run alone, so mixing them into a
  `Promise.all` serializes the whole batch. Set `background: true` on all of them.
- Capture first (`get_app_state` per app) so each app has geometry and indices.
- Check `sky.capabilities()` if background input misbehaves: `skylight.focus_without_raise:
  false` means this macOS build dropped the private symbols and background mode has
  fallen back to best-effort (menu shortcuts may not fire).
- Chromium apps: background right-click on **web content** gets coerced to
  left-click; use `perform_secondary_action` with `AXShowMenu` instead.

## Gotchas

- Actions activate the target app (steals focus) by default. Pass `background: true` on any action to work without stealing focus — see "Background & parallel work" below.
- If an action fails `approval_required`: the actuation allowlist is on — `skylight approve "<App>"` (`skylight` is on PATH with the cask), or `skylight allow-all` to disable the gate.
- Coordinates are **screenshot pixels**, not screen points — take them from the screenshot you just captured.
- `type_text` types at the current focus/caret — `click` the target field first unless the app focuses it for you.
- Apps may transform typed text (autocorrect, auto-capitalization) — verify by re-capture, not exact string match.
- Errors surface as `SkyError` with `.code` (e.g. `permission_denied` → check `skylight-run --status`; `actuation_paused` → a `SKYLIGHT_PAUSE` sentinel file exists under `~/Library/Application Support/skylight/`).
- Kill switch: `skylight-run --stop`. Every action is audit-logged to `~/Library/Logs/skylight/actuation.log`.
