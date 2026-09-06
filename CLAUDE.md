# Skylight

A macOS computer-use agent — a close reconstruction of OpenAI's "Sky"/CUAService
architecture (the engine inside the ChatGPT/Codex desktop app), adapted so
**Claude Code is the harness**. It lets an agent see and drive native Mac apps:
capture a window's accessibility tree + screenshot, then act on indexed elements
or raw coordinates.

## Architecture (three layers)

```
Claude / any client
  │  writes TS, runs `npx tsx script.ts`
  ▼
@skylight/sky  (TypeScript client, ts/)  ── one JSON object per line ──▶
  ▼  Unix socket: ~/Library/Application Support/skylight/ipc/computeruse.sock
SkylightService  (privileged Swift daemon)
   holds Accessibility + Screen Recording TCC grants
   AXUIElement tree walk · CGEvent/AX input · ScreenCaptureKit capture
```

The protocol is **line-delimited JSON** (not NSXPC): request
`{"id":n,"method":"...","params":{...}}`, response `{"id":n,"ok":true,"result":{...}}`
or `{"id":n,"ok":false,"error":{"code":"<slug>","message":"..."}}`.

## Layout

- `Sources/SkylightCore/` — the library (all logic, unit-tested):
  - `Clipboard.swift` — general pasteboard read/write (main-queue hop).
  - `IPC/` — `IPCServer` (0600 socket, per-request timeout, SIGPIPE-safe),
    `ActuationScheduler` (admission control: per-app keys run in parallel,
    `.exclusive` runs alone), `RequestClassifier` (which class a request gets),
    `LineCodec` (1 MiB line cap), `RequestRouter`.
  - `Protocol/` — `Messages` (wire envelopes, `JSONValue`, `SkyErrorCode`),
    `APITypes` (per-method input/output types).
  - `AX/` — `AXCapture` (live tree walk), `AXIdentity` (CFEqual/CFHash element
    key), `ElementIndexMap` (sticky index↔element map), `AXTreeSerializer`,
    `AXTreeDiff`, `TreeNode`.
  - `Actuation/` — `Actuator` (all actions), `Activation` (foreground raise +
    background focus-without-raise), `SkyLightBridge` (dlsym'd private window
    server symbols), `EventRecord` (the raw activation/key-window records),
    `KeyChord` (X-keysym chord → keycode+flags), `SelectionRange`.
  - `Screenshot/` — `Screenshotter` (SCK: window crops, whole-display
    `captureDisplay`, region `zoom`, `max_dimension` downscaling),
    `DisplayGeometryStore` (per-display click geometry), `AXWindowBridge`
    (`_AXUIElementGetWindow`).
  - `Geometry/CoordinateModel`, `AppRegistry`, `Permissions`, `Paths`, `AuditLog`.
- `Sources/SkylightService/main.swift` — the daemon: registers all methods, owns
  the run loop, audit log, kill switch.
- `Sources/skylight/main.swift` — the `skylight` CLI (`doctor`, `start`, `register`/`unregister`, approvals, usage).
- `ts/` — the `@skylight/sky` client (`src/client.ts`, `src/types.ts`,
  `sky.d.ts`) + tests, and `src/mcp.ts`, the MCP server (`skylight-run --mcp`)
  that exposes every method as a tool. `packaging/` (Info.plist + LaunchAgent), `scripts/`
  (`build.sh`, `install-local.sh`, `skylight-run`).

## Build / test

```bash
swift build                       # daemon binary → .build/debug/SkylightService
swift test                        # Swift unit tests (XCTest); must be 0 warnings
swift build 2>&1 | grep -i warning   # keep this EMPTY
(cd ts && npm install && npx vitest run)   # TS tests (vitest)
```

The live end-to-end smoke test is **gated**: `SKYLIGHT_SMOKE=1` runs it (needs
TCC grants + drives TextEdit); it's skipped by default so CI stays green.

`ts/live/` holds two manual checks for behavior unit tests cannot prove — that
the private focus-without-raise records are actually honored by the window
server, and that per-app parallelism shows up through a real socket. Run them
after a macOS upgrade; see `ts/live/README.md`.

## Running & driving the daemon (dev)

```bash
swift build && .build/debug/SkylightService &   # this machine's local binary has TCC grants
# then from ts/, write a .ts driver and run it:
npx tsx driver.ts
```

`ts/test/smoke.test.ts` is the canonical example of spawning the daemon and
driving it with the client. Stop the daemon with SIGTERM (it unlinks the socket).

## Install (Homebrew cask)

Skylight ships as a signed, notarized `SkylightService.app` via the
`baileywickham/tap` cask, on the same pipeline as ArtWall and Beads:

```bash
brew tap baileywickham/tap
brew install --cask skylight     # app → /Applications, `skylight` + `skylight-run` on PATH
skylight doctor                  # then grant Accessibility + Screen Recording (caveats)
```

The bundle carries everything: the daemon (`Contents/MacOS/SkylightService`),
the CLI (`Contents/MacOS/skylight`, so `Bundle.main` is the .app), the driver
wrapper (`Contents/Resources/bin/skylight-run`), the TS client source
(`Contents/Resources/ts`), and the LaunchAgent
(`Contents/Library/LaunchAgents/com.skylight.SkylightService.plist`,
`BundleProgram`-relative). The cask's postflight runs `skylight register`, which
registers that agent with `SMAppService` and starts the daemon — no separate
signing or install step, and `brew upgrade` just works. `skylight-run` stages
the TS client + `node_modules` under `~/Library/Application Support/skylight/ts-<version>`
on first run so the signed bundle is never written to.

Releases: `./release.sh patch` tags `vX.Y.Z`; `.github/workflows/release.yml`
runs `scripts/build.sh` (sign + notarize + DMG/ZIP), publishes the GitHub
release, then calls the tap's reusable `bump-cask` workflow to update the cask.
Dev install from a checkout: `scripts/install-local.sh` (same build, local
Developer ID / Apple Development identity, no notarization, `/Applications`).
Never run the daemon as a terminal child in installed mode: TCC keys the grants
to the launchd-launched .app.

## Conventions & gotchas (learned the hard way — don't regress these)

- **`npx tsx -e '...'` one-liners FAIL** here (esbuild CJS top-level-await). Write
  a `.ts`/`.mjs` file and run it, or add a vitest spec.
- **Never use `is`/`as?` to filter pure CoreFoundation types** (e.g. `AXUIElement`,
  `AXValue`). At runtime `$0 is AXUIElement` returns true for *any* CF type, so
  `unsafeDowncast` after it is UB. Filter with
  `CFGetTypeID($0) == AXUIElementGetTypeID()`.
- **Keyboard uses UTF-16 code units and the physical-key layout.** `type_text`
  chunks at UTF-16 boundaries (never split a surrogate pair). `press_key` remaps
  keycodes via `UCKeyTranslate` for the active layout — the QWERTY table is wrong
  on **Dvorak** (Cmd+C would post Cmd+J) — and posts real held `flagsChanged`
  modifier events so NSMenu equivalents (Cmd+C/V) actually fire.
- **Activation vs focus:** by default actions are activation-first (window comes
  to front). `SKYLIGHT_BACKGROUND=1` makes the daemon act **without stealing
  focus**: AX-index actions skip activation entirely, and event-delivering
  actions (coordinate click, keys, typing, scroll, drag) first run
  `focusWithoutRaise` — private `SLPSPostEventRecordTo` records that make the
  app AppKit-active and its window key **without raising it**, so menu
  equivalents (Cmd+c) fire. Chromium additionally needs a user-activation
  primer click at (-1,-1); Chromium still coerces synthetic right-clicks on web
  content to left-clicks, so use `perform_secondary_action`/`AXShowMenu` there.
  Every private symbol is dlsym-probed: when one is missing the whole path
  no-ops back to plain `CGEventPostToPid` (check `skylight doctor` or the
  `capabilities` method).
- **Concurrency invariant (important):** actuation is no longer one global
  serial queue. `ActuationScheduler` admits work by class — background actions
  and captures are `.keyed("pid:<n>")` (different apps run **in parallel**),
  foreground actions are `.exclusive` (run alone, since activation and the
  cursor are global). This is only sound because every mutable capture state is
  per-pid: `AXCapture.stateByPid` is lock-guarded, and the `AppCaptureState` /
  `ElementIndexMap` it hands out are deliberately unsynchronized because the
  scheduler guarantees one request at a time per app key. **If you add a method
  that touches per-app state, add it to `RequestClassifier`** — unlisted
  methods fall back to `.exclusive`, which is safe but serializes everything.
  Display captures (`screenshot`/`zoom`) share the `$display` key; clipboard
  and `list_displays` are meta.
  The app identifier is resolved to a pid *before* dispatch so `"Notes"` and
  `"com.apple.Notes"` cannot get two slots for one app.
- **Coordinate contract:** `click`/`drag` x/y are **screenshot pixels** of the
  latest image of that target; `global = px/scale + origin`. Per app the origin
  is the window's and the scale is whatever the window screenshot actually came
  back at (`max_dimension` can shrink it below the backing scale — main.swift
  re-commits the geometry with the returned scale, so image and click math
  never disagree). With `display_id` the same formula runs against
  `DisplayGeometryStore`'s latest `screenshot` of that display (default 1 px per
  point). `zoom` is read-only and never changes click geometry.
- **Sticky indices:** `element_index` values are stable per element across
  captures (keyed by CFEqual/CFHash), never reused. This is what makes diffing
  coherent and index→element resolution work. All map access stays on the serial queue.
- **AX robustness:** set `AXUIElementSetMessagingTimeout`; Chromium/Electron apps
  expose an empty tree until `AXManualAccessibility`/`AXEnhancedUserInterface` is
  set (first capture polls for the web area); node/depth caps with truncation markers.
- **TCC / signing:** the daemon must be launched via its LaunchAgent or `open -a`,
  **never as a terminal child** (TCC attributes the grant to the responsible
  process otherwise). Sign with a **stable identity** (not ad-hoc — ad-hoc cdhash
  changes every build and drops grants); `SKYLIGHT_SIGNING_IDENTITY` overrides
  the default. `skylight doctor` reports grant status.
- **Screenshots** are written to disk under an **absolute** dir
  (`~/Library/Application Support/skylight/shots`, override `SKYLIGHT_SHOTS_DIR`)
  and returned as a `file://` URL; inline base64 `data_url` is opt-in
  (`include_data_url: true`). Never default the shots dir to a cwd-relative path
  (breaks under launchd, whose cwd is `/`).
- **Kill switch:** SIGTERM, or a `SKYLIGHT_PAUSE` sentinel file (under the support
  dir) halts actuation → `actuation_paused`. Every actuation is logged to
  `~/Library/Logs/skylight/actuation.log`.
- **Cross-layer contract:** Swift `APITypes`, TS `types.ts`/`sky.d.ts`, and
  `ts/../contracts/fixtures.json` must agree — the contract test (`ts/test/contract.test.ts`
  + `ContractTests.swift`) reads one shared fixture file, so a field rename on
  either side fails. Fields are snake_case except `disableDiff` (camelCase, matches
  the reference API).

- **Implicit app targets:** `press_key`/`type_text` without `app` go to the
  frontmost app; `click`/`drag` with `display_id` and no `app` hit-test the
  point (`AXUIElementCopyElementAtPosition` on the system-wide element) and
  fall back to frontmost. Both still pass the approvals gate. Apps without a
  focused window (menu-bar apps, bare dialogs) are activated without a raise.
- **Spaces:** `SkyLightBridge` also dlsyms the Spaces symbols
  (`SLSGetActiveSpace`, `SLSCopySpacesForWindows`, `SLSMoveWindowsToManagedSpace`,
  and the `SLSSpaceSetCompatID`+`SLSSetWindowListWorkspace` workaround yabai
  uses where the direct move is ignored). `bring_to_active_space` tries the
  direct move, then the workaround, and reports `moved` only after re-reading
  the window's Spaces — never trust the call, verify. Reported as
  `capabilities.skylight.space_management`.

## API methods

`capabilities` (TCC grants + which private SkyLight capabilities resolved +
`background_default`/`parallel_actuation` — check this before assuming
background mode is fully reliable on a given macOS build),
`list_apps` (regular apps; `include_menu_bar_apps` adds accessory/LSUIElement
apps tagged `menu_bar_only` — always resolvable by name regardless),
`list_windows` (per-app windows with CGWindowIDs), `get_app_state`
(AX text + screenshot; diffs by default, `disableDiff` forces full; `window_id`
targets a non-focused window; degrades to AX-only + `screenshot_error` when the
screenshot fails; window-less menu-bar apps capture a synthetic `AXMenuBarApp`
root over the status item + open popover — see `AX/MenuBarApp.swift` for the
popover's key-status-dependent attachment quirk), `click` (element_index OR x/y),
`press_key`, `type_text`,
`scroll`, `set_value`, `drag`, `perform_secondary_action`, `select_text`, plus
`ping`/`echo`. Every action takes optional `background: true` (per-request
no-focus-steal override). Pixel path: `list_displays`, `screenshot` (whole
display, default 1 px/pt, `max_dimension` cap, cursor shown), `zoom` (native
crop of a region of the latest screenshot), and `click`/`drag` with
`display_id`. Also `read_clipboard`/`write_clipboard` (not app-scoped, so not
approval-gated; the write is audited) and `bring_to_active_space`.
`get_app_state` accepts `max_dimension` too. `list_windows` reports
`is_on_active_space` when the Spaces bridge resolved. Actuation is gated by the opt-in per-app allowlist in
`~/Library/Application Support/skylight/approvals.json` (`skylight approve`);
unlisted apps fail `approval_required`. The allowlist is a guardrail, not a
security boundary — any local process of this user can edit the file or drive
the socket directly. See `ts/sky.d.ts`.

## MCP server

`skylight-run --mcp` serves the daemon over stdio (`ts/src/mcp.ts`, using
`@modelcontextprotocol/sdk`). Register once with
`claude mcp add --scope user skylight -- ~/bin/skylight-run --mcp`; the tools
then appear as `mcp__skylight__*`. Screenshots return as image content, capped
at `SKYLIGHT_MCP_MAX_DIMENSION` (default 1568) on the long side; the daemon
keeps the matching geometry so coordinates the model reads off an image are
passed straight back. Nothing in the `--mcp` path may write to stdout except
the transport.

## Docs

Design spec, implementation plan, and the task-by-task build/review log live under
`docs/superpowers/` and `.superpowers/sdd/progress.md` (the latter records every
deferred/triaged finding — read it before assuming something is a fresh bug).
