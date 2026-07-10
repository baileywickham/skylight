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
  - `IPC/` — `IPCServer` (0600 socket, single global serial actuation queue,
    per-request timeout, SIGPIPE-safe), `LineCodec` (1 MiB line cap),
    `RequestRouter`.
  - `Protocol/` — `Messages` (wire envelopes, `JSONValue`, `SkyErrorCode`),
    `APITypes` (per-method input/output types).
  - `AX/` — `AXCapture` (live tree walk), `AXIdentity` (CFEqual/CFHash element
    key), `ElementIndexMap` (sticky index↔element map), `AXTreeSerializer`,
    `AXTreeDiff`, `TreeNode`.
  - `Actuation/` — `Actuator` (all actions), `Activation`, `KeyChord` (X-keysym
    chord → keycode+flags), `SelectionRange` (select_text math).
  - `Screenshot/` — `Screenshotter` (SCK), `AXWindowBridge` (`_AXUIElementGetWindow`).
  - `Geometry/CoordinateModel`, `AppRegistry`, `Permissions`, `Paths`, `AuditLog`.
- `Sources/SkylightService/main.swift` — the daemon: registers all methods, owns
  the run loop, audit log, kill switch.
- `Sources/skylight/main.swift` — the `skylight` CLI (`doctor`, `start`, usage).
- `ts/` — the `@skylight/sky` client (`src/client.ts`, `src/types.ts`,
  `sky.d.ts`) + tests. `packaging/`, `scripts/` — .app + LaunchAgent + signing.

## Build / test

```bash
swift build                       # daemon binary → .build/debug/SkylightService
swift test                        # Swift unit tests (XCTest); must be 0 warnings
swift build 2>&1 | grep -i warning   # keep this EMPTY
(cd ts && npm install && npx vitest run)   # TS tests (vitest)
```

The live end-to-end smoke test is **gated**: `SKYLIGHT_SMOKE=1` runs it (needs
TCC grants + drives TextEdit); it's skipped by default so CI stays green.

## Running & driving the daemon (dev)

```bash
swift build && .build/debug/SkylightService &   # this machine's local binary has TCC grants
# then from ts/, write a .ts driver and run it:
npx tsx driver.ts
```

`ts/test/smoke.test.ts` is the canonical example of spawning the daemon and
driving it with the client. Stop the daemon with SIGTERM (it unlinks the socket).

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
  focus**: AX-index actions skip activation (reliable); coordinate/keyboard use
  `CGEventPostToPid` (best-effort — menu shortcuts to a background app may not fire).
- **Coordinate contract:** `click`/`drag` x/y are **screenshot pixels**;
  `global = px/backingScale + windowOrigin`. One `captureGeometry`/`backingScaleFactor`
  source feeds both the screenshot dimensions and the click conversion — keep it that way.
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

## API methods

`list_apps`, `get_app_state` (AX text + screenshot; diffs by default,
`disableDiff` forces full), `click` (element_index OR x/y), `press_key`,
`type_text`, `scroll`, `set_value`, `drag`, `perform_secondary_action`,
`select_text`, plus `ping`/`echo`. See `ts/sky.d.ts` for the model-facing surface.

## Docs

Design spec, implementation plan, and the task-by-task build/review log live under
`docs/superpowers/` and `.superpowers/sdd/progress.md` (the latter records every
deferred/triaged finding — read it before assuming something is a fresh bug).
