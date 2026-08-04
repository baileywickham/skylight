---
name: skylight
description: Use when asked to see, read, click, type into, or otherwise drive a native macOS app (computer use on this Mac — TextEdit, Finder, Messages, Notes, any app window), take a window screenshot with its accessibility tree, or when the user mentions Skylight or skylight-run.
---

# Skylight — driving native macOS apps

Skylight (repo: `~/workspace/skylight`) is a local computer-use daemon: it captures an app window's accessibility (AX) tree + screenshot, and performs clicks/keys/typing on it. `skylight-run` (on PATH) wraps everything — daemon startup, module-format gotchas — so drivers work from any directory.

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
`import { sky } from '/Users/baileywickham/workspace/skylight/ts/src/index.js'`
then `skylight-run driver.mts`. End with `sky.close()`.

Other commands: `skylight-run --status` (permissions/socket report), `skylight-run --stop`.

## Workflow

1. `get_app_state` → read the indexed AX tree (`s.text`) and/or screenshot (`s.screenshot?.url` — may be absent with `s.screenshot_error` set when Screen Recording is ungranted; the AX text still works).
2. Act by `element_index` (preferred — stable across captures) or screenshot-pixel `x`/`y`.
3. Re-capture to verify; repeat. Captures after the first return **diffs** by default; pass `disableDiff: true` for the full tree.

## API quick reference

All methods take `app` (app name, e.g. `"Finder"`). Full types: `~/workspace/skylight/ts/sky.d.ts`.

| Method | Key params |
|---|---|
| `list_apps` | `include_menu_bar_apps?` (also list accessory/LSUIElement apps, tagged `menu_bar_only`) |
| `list_windows` | — (windows with `window_id`, `title`, `is_focused`) |
| `get_app_state` | `disableDiff?`, `window_id?` (from `list_windows`), `include_data_url?` |
| `click` | `element_index` OR `x`,`y` (screenshot px); `mouse_button?`, `click_count?` |
| `press_key` | `keys`: X-keysym chord, e.g. `"Cmd+s"`, `"Ctrl+Shift+t"`, `"Return"` |
| `type_text` | `text` |
| `scroll` | `element_index`, `direction` (up/down/left/right), `pages` |
| `set_value` | `element_index`, `value` |
| `drag` | `from_x`,`from_y`,`to_x`,`to_y` (screenshot px) |
| `perform_secondary_action` | `element_index`, `action` (e.g. `"AXShowMenu"`) |
| `select_text` | `element_index`, `text`, `prefix?`, `suffix?`, `selection_type` |

Every action (`click`, `press_key`, `type_text`, `scroll`, `set_value`, `drag`, `perform_secondary_action`, `select_text`) also accepts `background?: true`.

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

## Gotchas

- Actions activate the target app (steals focus) by default. Pass `background: true` on any action to act without stealing focus — reliable for `element_index` actions, best-effort for coordinates/keys (menu shortcuts need frontmost).
- If an action fails `approval_required`: the actuation allowlist is on — `skylight approve "<App>"` (binary: `~/workspace/skylight/.build/debug/skylight`), or `skylight allow-all` to disable the gate.
- Coordinates are **screenshot pixels**, not screen points — take them from the screenshot you just captured.
- `type_text` types at the current focus/caret — `click` the target field first unless the app focuses it for you.
- Apps may transform typed text (autocorrect, auto-capitalization) — verify by re-capture, not exact string match.
- Errors surface as `SkyError` with `.code` (e.g. `permission_denied` → check `skylight-run --status`; `actuation_paused` → a `SKYLIGHT_PAUSE` sentinel file exists under `~/Library/Application Support/skylight/`).
- Kill switch: `skylight-run --stop`. Every action is audit-logged to `~/Library/Logs/skylight/actuation.log`.
