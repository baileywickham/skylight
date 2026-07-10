# Sky Parity Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the five functionality gaps vs OpenAI's Sky identified in the 2026-07-10 review: multi-window addressing (`list_windows` + `window_id`), per-request background mode, AX-only capture fallback, a per-app approval allowlist, and per-app notes in the user's skylight skill.

**Architecture:** All five are extensions of the existing three-layer design (TS client → line-JSON socket → Swift daemon). Wire-type changes ripple through four places that the contract tests force to agree: `Sources/SkylightCore/Protocol/APITypes.swift`, `ts/src/types.ts`, `contracts/fixtures.json`, and the two contract test files. New daemon logic lives in `SkylightCore` (unit-testable); `Sources/SkylightService/main.swift` only wires it up.

**Tech Stack:** Swift 5 (XCTest), TypeScript (vitest), line-delimited JSON over Unix socket.

## Global Constraints

- `swift build 2>&1 | grep -i warning` must stay EMPTY (zero warnings).
- Wire fields are snake_case, except `disableDiff` (camelCase, matches the reference API).
- Swift `APITypes`, TS `types.ts`, and `contracts/fixtures.json` must agree — the shared-fixture contract tests (`Tests/SkylightCoreTests/ContractTests.swift`, `ts/test/contract.test.ts`) fail on any drift. Every wire change updates all of them in the same task.
- Never use `is`/`as?` to filter pure CF types (`AXUIElement`, `AXValue`); filter with `CFGetTypeID($0) == AXUIElementGetTypeID()`.
- AXCapture/ElementIndexMap/Actuator are NOT thread-safe; everything stays on the daemon's global serial actuation queue (already true — don't add threads).
- Swift optional fields use synthesized Codable (encodeIfPresent — nil keys are omitted from the wire); TS mirrors them as `field?: T | null`.
- Run full `swift test` and `(cd ts && npx vitest run)` before every commit; both must pass.
- All work on branch `sky-parity`.

**Verification commands (used throughout):**
- Swift: `swift test 2>&1 | grep -E "Executed .* tests"` → expect `0 failures`
- TS: `cd ts && npx vitest run` → expect all pass
- Warnings: `swift build 2>&1 | grep -i warning` → expect empty
- Live (needs granted daemon; run from repo root): `scripts/skylight-run -e '<code>'`

---

### Task 1: AX-only capture fallback (`screenshot` optional + `screenshot_error`)

When the screenshot fails (Screen Recording ungranted/lapsed, transient SCK error), `get_app_state` currently fails entirely. Instead, degrade: return the AX tree with `screenshot` omitted and a `screenshot_error` string. The diff baseline DOES commit on the degraded path — the model received the tree, so advancing is correct (the I1 invariant was "never advance past a tree the model never saw", and it saw this one).

**Files:**
- Modify: `Sources/SkylightCore/Protocol/APITypes.swift:36-45` (AppState)
- Modify: `Sources/SkylightService/main.swift:87-100` (get_app_state handler)
- Modify: `contracts/fixtures.json` (app_state fixtures)
- Modify: `Tests/SkylightCoreTests/APITypesTests.swift` (add round-trip test)
- Modify: `ts/src/types.ts:29-34` (AppState)
- Modify: `ts/test/contract.test.ts:32-36` (AppState branch)

**Interfaces:**
- Produces: `AppState(text:screenshot:screenshot_error:diffed:)` with `screenshot: ScreenshotResult?`, `screenshot_error: String?`. Task 6 documents this; no other task consumes it.

- [ ] **Step 1: Write the failing Swift test**

Add to `Tests/SkylightCoreTests/APITypesTests.swift`:

```swift
    func testAppStateAXOnlyOmitsScreenshotAndCarriesError() throws {
        let state = AppState(text: "[0] AXWindow", screenshot: nil,
                             screenshot_error: "permission_denied: Screen Recording not granted",
                             diffed: true)
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"screenshot\":"), "nil screenshot must be omitted from the wire")
        XCTAssertTrue(json.contains("\"screenshot_error\":"))
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
```

- [ ] **Step 2: Run it — expect compile FAILURE** (`AppState` has no `screenshot_error`): `swift test --filter APITypesTests 2>&1 | tail -5`

- [ ] **Step 3: Change AppState in `Sources/SkylightCore/Protocol/APITypes.swift`**

Replace the existing `AppState` struct (lines 36-45) with:

```swift
public struct AppState: Codable, Equatable {
    public let text: String
    /// nil when the screenshot failed but the AX capture succeeded (AX-only
    /// degraded response); `screenshot_error` then says why.
    public let screenshot: ScreenshotResult?
    public let screenshot_error: String?
    public let diffed: Bool
    public init(text: String, screenshot: ScreenshotResult?, screenshot_error: String? = nil, diffed: Bool) {
        self.text = text
        self.screenshot = screenshot
        self.screenshot_error = screenshot_error
        self.diffed = diffed
    }
}
```

- [ ] **Step 4: Update the get_app_state handler in `Sources/SkylightService/main.swift`**

Replace the `router.register("get_app_state", ...)` block (lines 87-100) with:

```swift
router.register("get_app_state", handle("get_app_state", GetAppStateInput.self) { input in
    let app = try registry.resolve(input.app)
    let captured = try axCapture.capture(app: app, disableDiff: input.disableDiff ?? false)
    // AX-only fallback: a failed screenshot (Screen Recording ungranted or
    // lapsed — macOS 15 re-prompts periodically — or a transient SCK error)
    // degrades the response instead of failing it; the model still gets the
    // tree, so the diff baseline below still commits (I1's invariant is
    // "never advance past a tree the model never saw" — it saw this one).
    var shot: ScreenshotResult?
    var shotError: String?
    do {
        shot = try awaitResult {
            try await screenshotter.capture(window: captured.window,
                                            includeDataURL: input.include_data_url ?? false)
        }
    } catch let error as SkyServiceError {
        shotError = "\(error.code.rawValue): \(error.message)"
    }
    axCapture.commitBaseline(captured, forPid: app.processIdentifier)
    auditLog.record(method: "get_app_state", target: input.app,
                    outcome: shotError == nil ? "ok" : "ok-ax-only")
    return AppState(text: captured.text, screenshot: shot,
                    screenshot_error: shotError, diffed: captured.diffed)
})
```

- [ ] **Step 5: Update fixtures — `contracts/fixtures.json`**

In the `responses` array, after the existing `app_state` entry, add:

```json
    { "name": "app_state_ax_only", "decodes_to": "AppState", "json": { "text": "[0] AXWindow \"Untitled\"", "screenshot_error": "permission_denied: Screen Recording not granted", "diffed": true } },
```

- [ ] **Step 6: Update TS — `ts/src/types.ts`**

Replace the `AppState` interface with:

```typescript
export interface AppState {
  /** Indexed accessibility text: full tree, or a diff when diffed is true (M2). */
  text: string;
  /** Absent when the screenshot failed but AX capture succeeded (AX-only degraded response). */
  screenshot?: Screenshot | null;
  /** Present exactly when screenshot is absent: "<code>: <message>". */
  screenshot_error?: string | null;
  diffed: boolean;
}
```

In `ts/test/contract.test.ts`, replace the AppState branch with:

```typescript
      } else if (resp.decodes_to === "AppState") {
        const r = resp.json as AppState;
        expect(typeof r.text).toBe("string");
        if (r.screenshot != null) expect(typeof r.screenshot.url).toBe("string");
        else expect(typeof r.screenshot_error).toBe("string");
        expect(typeof r.diffed).toBe("boolean");
      } else if (resp.decodes_to === "ActionResult") {
```

- [ ] **Step 7: Run everything**

`swift test 2>&1 | grep -E "Executed|failure"` → 0 failures. `swift build 2>&1 | grep -i warning` → empty. `cd ts && npx vitest run` → pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/SkylightCore/Protocol/APITypes.swift Sources/SkylightService/main.swift contracts/fixtures.json Tests/SkylightCoreTests/APITypesTests.swift ts/src/types.ts ts/test/contract.test.ts
git commit -m "feat: AX-only get_app_state fallback when the screenshot fails"
```

---

### Task 2: `list_windows` method

New wire method: enumerate an app's windows with stable ids so a client can see and (Task 3) target non-focused windows. Window identity = CGWindowID via the existing `axWindowID` bridge (`Sources/SkylightCore/Screenshot/AXWindowBridge.swift`); `window_id` is null per-window if the private bridge is unavailable.

**Files:**
- Modify: `Sources/SkylightCore/Protocol/APITypes.swift` (WindowInfo, ListWindowsResult, ListWindowsInput)
- Modify: `Sources/SkylightCore/AX/AXCapture.swift` (windowListings)
- Modify: `Sources/SkylightService/main.swift` (register list_windows)
- Modify: `contracts/fixtures.json`, `Tests/SkylightCoreTests/ContractTests.swift`, `ts/test/contract.test.ts`
- Modify: `ts/src/types.ts`, `ts/src/client.ts`

**Interfaces:**
- Consumes: `axWindowID(of:) -> CGWindowID?`, `sanitizeAXText(_:)`, `axAttribute(_:_:)` (all existing in SkylightCore).
- Produces: `AXCapture.windowListings(of: NSRunningApplication) throws -> [WindowListing]` where `WindowListing` is `{element: AXUIElement, info: WindowInfo}` — Task 3 uses it to resolve `window_id` → element. `WindowInfo(window_id: Int?, title: String?, is_focused: Bool, is_minimized: Bool)`.

- [ ] **Step 1: Add wire types to `Sources/SkylightCore/Protocol/APITypes.swift`** (after `ListAppsResult`):

```swift
public struct WindowInfo: Codable, Equatable {
    /// CGWindowID from the _AXUIElementGetWindow bridge; nil when the private
    /// symbol is unavailable (window then can't be targeted by window_id).
    public let window_id: Int?
    public let title: String?
    public let is_focused: Bool
    public let is_minimized: Bool
    public init(window_id: Int?, title: String?, is_focused: Bool, is_minimized: Bool) {
        self.window_id = window_id
        self.title = title
        self.is_focused = is_focused
        self.is_minimized = is_minimized
    }
}

public struct ListWindowsResult: Codable, Equatable {
    public let windows: [WindowInfo]
    public init(windows: [WindowInfo]) { self.windows = windows }
}

public struct ListWindowsInput: Codable, Equatable {
    public let app: String
    public init(app: String) { self.app = app }
}
```

- [ ] **Step 2: Update fixtures + BOTH contract tests (write the failing tests)**

`contracts/fixtures.json` — in `requests`, after the `list_apps` entry, add:

```json
    { "method": "list_windows", "params": { "app": "Notes" }, "line": "{\"id\":1,\"method\":\"list_windows\",\"params\":{\"app\":\"Notes\"}}" },
```

In `responses`, after `list_apps`, add:

```json
    { "name": "list_windows", "decodes_to": "ListWindowsResult", "json": { "windows": [{ "window_id": 4242, "title": "Untitled", "is_focused": true, "is_minimized": false }] } },
```

`Tests/SkylightCoreTests/ContractTests.swift` — add to the method switch (after `case "list_apps"`):

```swift
            case "list_windows": _ = try request.decodeParams(ListWindowsInput.self)
```

and to the response switch (after `case "ListAppsResult"`):

```swift
            case "ListWindowsResult": _ = try JSONDecoder().decode(ListWindowsResult.self, from: data)
```

`ts/test/contract.test.ts` — add to the response type checks (after the ListAppsResult branch):

```typescript
      } else if (resp.decodes_to === "ListWindowsResult") {
        const r = resp.json as ListWindowsResult;
        expect(Array.isArray(r.windows)).toBe(true);
        expect(typeof r.windows[0].is_focused).toBe("boolean");
```

and add `ListWindowsResult` to the type import at the top of the file.

- [ ] **Step 3: Run TS test — expect FAIL** (`ListWindowsResult` not exported): `cd ts && npx vitest run` — then add the TS types.

`ts/src/types.ts` (after `ListAppsResult`):

```typescript
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
```

`ts/src/client.ts` — add after the `list_apps` method (import `ListWindowsInput, ListWindowsResult` in the types import at the top):

```typescript
  list_windows(input: ListWindowsInput): Promise<ListWindowsResult> { return this.call("list_windows", input); }
```

- [ ] **Step 4: Implement `windowListings` in `Sources/SkylightCore/AX/AXCapture.swift`** (after `focusedWindow(of:)`):

```swift
    /// One entry per AX window of the app, with the wire-facing WindowInfo and
    /// the live element (used by window_id-targeted capture). Ordered as the
    /// app reports kAXWindowsAttribute.
    public struct WindowListing {
        public let element: AXUIElement
        public let info: WindowInfo
    }

    public func windowListings(of app: NSRunningApplication) throws -> [WindowListing] {
        guard Permissions.status().accessibility else {
            let instructions = Permissions.instructions(
                for: PermissionStatus(accessibility: false, screen_recording: true))
            throw SkyServiceError(code: .permissionDenied,
                                  message: instructions.joined(separator: " "))
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let focused: AXUIElement? = axAttribute(appElement, kAXFocusedWindowAttribute)
        let wins: [AXUIElement] = (axAttribute(appElement, kAXWindowsAttribute) as CFArray?)
            .map { cfArray -> [AXUIElement] in
                // CFTypeID is the only runtime-correct filter for CF types.
                let array = cfArray as [AnyObject]
                return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                    .map { unsafeDowncast($0, to: AXUIElement.self) }
            } ?? []
        return wins.map { w in
            let minimized: NSNumber? = axAttribute(w, kAXMinimizedAttribute)
            let title: String? = axAttribute(w, kAXTitleAttribute)
            return WindowListing(element: w, info: WindowInfo(
                window_id: axWindowID(of: w).map { Int($0) },
                title: title.map { sanitizeAXText($0) },
                is_focused: focused.map { CFEqual($0, w) } ?? false,
                is_minimized: minimized?.boolValue ?? false))
        }
    }
```

- [ ] **Step 5: Register the method in `Sources/SkylightService/main.swift`** (after the `list_apps` registration):

```swift
router.register("list_windows", handle("list_windows", ListWindowsInput.self) { input in
    let app = try registry.resolve(input.app)
    return ListWindowsResult(windows: try axCapture.windowListings(of: app).map(\.info))
})
```

- [ ] **Step 6: Run everything** — `swift test`, warning grep, `npx vitest run`. All green.

- [ ] **Step 7: Live check** (needs granted daemon):

```bash
scripts/skylight-run -e 'console.log(JSON.stringify(await sky.list_windows({ app: "Finder" }), null, 1))'
```

Expected: at least one window with numeric `window_id`, one `is_focused: true`.

- [ ] **Step 8: Commit**

```bash
git add Sources/SkylightCore/Protocol/APITypes.swift Sources/SkylightCore/AX/AXCapture.swift Sources/SkylightService/main.swift contracts/fixtures.json Tests/SkylightCoreTests/ContractTests.swift ts/src/types.ts ts/src/client.ts ts/test/contract.test.ts
git commit -m "feat: list_windows method with CGWindowID-based window identity"
```

---

### Task 3: `window_id` targeting on `get_app_state` + window-aware diff baseline

`get_app_state` gains optional `window_id`. Capture resolves that window instead of the focused one. The per-app diff baseline becomes window-aware: diffing a capture of window B against a baseline from window A would emit a giant bogus diff, so a window change forces a full tree. When window ids are unavailable (no bridge), behavior stays exactly as today.

**Files:**
- Modify: `Sources/SkylightCore/Protocol/APITypes.swift` (GetAppStateInput)
- Modify: `Sources/SkylightCore/AX/AXCapture.swift` (capture signature, CaptureResult, AppCaptureState, canDiff)
- Modify: `Sources/SkylightService/main.swift` (pass window_id)
- Modify: `Tests/SkylightCoreTests/AXCaptureTests.swift` (canDiff tests)
- Modify: `contracts/fixtures.json`, `ts/src/types.ts`

**Interfaces:**
- Consumes: `windowListings(of:)` from Task 2.
- Produces: `AXCapture.capture(app:windowID:disableDiff:) throws -> CaptureResult` (windowID defaults to nil — existing callers compile unchanged); `CaptureResult.windowID: Int?`; pure `canDiff(disableDiff:hasPrevious:previousWindowID:currentWindowID:) -> Bool`.

- [ ] **Step 1: Write the failing pure-logic test** in `Tests/SkylightCoreTests/AXCaptureTests.swift`:

```swift
    func testCanDiffIsWindowAware() {
        // No previous capture or diff disabled: never diff.
        XCTAssertFalse(canDiff(disableDiff: false, hasPrevious: false, previousWindowID: 1, currentWindowID: 1))
        XCTAssertFalse(canDiff(disableDiff: true, hasPrevious: true, previousWindowID: 1, currentWindowID: 1))
        // Same window: diff.
        XCTAssertTrue(canDiff(disableDiff: false, hasPrevious: true, previousWindowID: 7, currentWindowID: 7))
        // Different window: a diff against another window's tree is bogus — full tree.
        XCTAssertFalse(canDiff(disableDiff: false, hasPrevious: true, previousWindowID: 7, currentWindowID: 8))
        // Ids unavailable (bridge missing) on either side: preserve the old
        // per-app diff behavior rather than degrading to full-tree-always.
        XCTAssertTrue(canDiff(disableDiff: false, hasPrevious: true, previousWindowID: nil, currentWindowID: 7))
        XCTAssertTrue(canDiff(disableDiff: false, hasPrevious: true, previousWindowID: 7, currentWindowID: nil))
    }
```

- [ ] **Step 2: Run — expect compile FAILURE** (`canDiff` undefined): `swift test --filter AXCaptureTests 2>&1 | tail -3`

- [ ] **Step 3: Implement in `Sources/SkylightCore/AX/AXCapture.swift`**

Top-level (near `needsWebAreaRetry`):

```swift
/// Window-aware diff gate: diff only against a baseline from the SAME window.
/// When either window id is unknown (private bridge unavailable) fall back to
/// the original per-app behavior — better an occasional cross-window diff on
/// bridge-less machines than never diffing at all there.
public func canDiff(disableDiff: Bool, hasPrevious: Bool,
                    previousWindowID: Int?, currentWindowID: Int?) -> Bool {
    guard !disableDiff, hasPrevious else { return false }
    guard let prev = previousWindowID, let cur = currentWindowID else { return true }
    return prev == cur
}
```

`CaptureResult` gains a field (add `public let windowID: Int?` after `geometry`, add `windowID: Int?` to the init and assign it — update the full init signature to `init(text:lines:window:geometry:windowID:diffed:)`).

`AppCaptureState` gains `var previousWindowID: Int?`.

In `capture(app:disableDiff:)`: change the signature to

```swift
    public func capture(app: NSRunningApplication, windowID: Int? = nil, disableDiff: Bool) throws -> CaptureResult {
```

Replace `let window = try focusedWindow(of: app)` with:

```swift
        let window: AXUIElement
        if let id = windowID {
            guard let match = try windowListings(of: app).first(where: { $0.info.window_id == id }) else {
                throw SkyServiceError(code: .noFocusedWindow,
                                      message: "window_id \(id) not found for '\(app.localizedName ?? "app")' — call list_windows for current ids")
            }
            window = match.element
        } else {
            window = try focusedWindow(of: app)
        }
        let currentWindowID = axWindowID(of: window).map { Int($0) }
```

Replace the diff decision block:

```swift
        let outputText: String
        let diffed: Bool
        if canDiff(disableDiff: disableDiff, hasPrevious: s.previousLines != nil,
                   previousWindowID: s.previousWindowID, currentWindowID: currentWindowID),
           let previous = s.previousLines {
            outputText = diffTrees(previous: previous, current: serialized.lines)
            diffed = true
        } else {
            outputText = serialized.text
            diffed = false
        }

        return CaptureResult(text: outputText, lines: serialized.lines, window: window,
                             geometry: geometry, windowID: currentWindowID, diffed: diffed)
```

In `commitBaseline(_:forPid:)` add `s.previousWindowID = result.windowID`.

- [ ] **Step 4: Wire the input through**

`Sources/SkylightCore/Protocol/APITypes.swift` — replace `GetAppStateInput` with:

```swift
public struct GetAppStateInput: Codable, Equatable {
    public let app: String
    /// Target a specific window (id from list_windows). Default: focused window.
    public let window_id: Int?
    public let disableDiff: Bool?
    public let include_data_url: Bool?
    public init(app: String, window_id: Int? = nil, disableDiff: Bool? = nil, include_data_url: Bool? = nil) {
        self.app = app
        self.window_id = window_id
        self.disableDiff = disableDiff
        self.include_data_url = include_data_url
    }
}
```

`Sources/SkylightService/main.swift` get_app_state handler: change the capture line to

```swift
    let captured = try axCapture.capture(app: app, windowID: input.window_id,
                                         disableDiff: input.disableDiff ?? false)
```

`ts/src/types.ts` — add to `GetAppStateInput`:

```typescript
  /** Target a specific window (id from list_windows). Default: focused window. */
  window_id?: number;
```

`contracts/fixtures.json` — in `requests`, after the second get_app_state entry, add:

```json
    { "method": "get_app_state", "params": { "app": "Notes", "window_id": 4242 }, "line": "{\"id\":1,\"method\":\"get_app_state\",\"params\":{\"app\":\"Notes\",\"window_id\":4242}}" },
```

- [ ] **Step 5: Fix any `CaptureResult(...)` call sites in tests** — grep: `grep -rn "CaptureResult(" Tests/ Sources/` and add `windowID: nil` (or a value) to each init call that doesn't compile.

- [ ] **Step 6: Run everything** — `swift test`, warning grep, `npx vitest run`. All green.

- [ ] **Step 7: Live check** — capture a specific non-focused window:

```bash
scripts/skylight-run -e '
const wins = await sky.list_windows({ app: "Finder" });
const target = wins.windows.find(w => w.window_id != null);
const s = await sky.get_app_state({ app: "Finder", window_id: target.window_id, disableDiff: true });
console.log("targeted", target.window_id, "->", s.text.split("\n")[0]);'
```

Expected: first tree line names the targeted window.

- [ ] **Step 8: Commit**

```bash
git add Sources/SkylightCore Sources/SkylightService contracts/fixtures.json Tests ts/src/types.ts
git commit -m "feat: window_id targeting on get_app_state with window-aware diff baseline"
```

---

### Task 4: per-request `background` override

Every action input gains optional `background`; `input.background ?? daemonDefault` decides activation and event routing per call. `SKYLIGHT_BACKGROUND=1` keeps working as the default.

**Files:**
- Modify: `Sources/SkylightCore/Protocol/APITypes.swift` (8 action inputs)
- Modify: `Sources/SkylightCore/Actuation/Actuator.swift`
- Modify: `Tests/SkylightCoreTests/ActuatorTests.swift`
- Modify: `contracts/fixtures.json`, `ts/src/types.ts`

**Interfaces:**
- Produces: `Actuator.effectiveBackground(_ override: Bool?) -> Bool` (public, pure). All 8 wire inputs gain `background: Bool?` as the LAST init parameter, defaulted nil — existing positional call sites compile unchanged.

- [ ] **Step 1: Write the failing test** in `Tests/SkylightCoreTests/ActuatorTests.swift`:

```swift
    func testEffectiveBackgroundPerRequestOverride() {
        let registry = AppRegistry()
        let capture = AXCapture()
        let fg = Actuator(registry: registry, capture: capture, background: false)
        let bg = Actuator(registry: registry, capture: capture, background: true)
        XCTAssertFalse(fg.effectiveBackground(nil), "no override: daemon default (foreground)")
        XCTAssertTrue(fg.effectiveBackground(true), "request opts INTO background")
        XCTAssertTrue(bg.effectiveBackground(nil), "no override: daemon default (background)")
        XCTAssertFalse(bg.effectiveBackground(false), "request opts OUT of background")
    }
```

(Match the existing `Actuator(...)` construction style used elsewhere in `ActuatorTests.swift` — if its tests pass `pauseFile:`, mirror that.)

- [ ] **Step 2: Run — expect compile FAILURE**: `swift test --filter ActuatorTests 2>&1 | tail -3`

- [ ] **Step 3: Implement in `Sources/SkylightCore/Actuation/Actuator.swift`**

Rename the stored property `background` → `defaultBackground` (keep the init label `background:` for source compatibility):

```swift
    /// Daemon-wide default (SKYLIGHT_BACKGROUND=1). Each action may override
    /// per request via its optional `background` field.
    private let defaultBackground: Bool
```

and in init: `self.defaultBackground = background`. Add:

```swift
    /// Per-request override wins; absent falls back to the daemon default.
    public func effectiveBackground(_ override: Bool?) -> Bool {
        override ?? defaultBackground
    }
```

Change the two routing helpers to take the resolved flag:

```swift
    private func raiseUnlessBackground(app: NSRunningApplication, window: AXUIElement, background: Bool) {
        guard shouldActivate(background: background) else { return }
        activateAndRaise(app: app, window: window)
    }

    private func post(_ event: CGEvent?, pid: pid_t, background: Bool) {
        switch eventDestination(background: background, targetPid: pid) {
        case .session: event?.post(tap: .cghidEventTap)
        case .pid(let pid): event?.postToPid(pid)
        }
    }
```

In EACH of the 8 actions, compute `let background = effectiveBackground(input.background)` right after `try guardNotPaused()`, then pass `background: background` at every `raiseUnlessBackground(...)` and `post(..., pid: ...)` call site in that action. (Mechanical: `click` has 1 raise + 2 posts in the coordinate branch and 1 raise in the element branch; `pressKey` 1 raise + 1 post; `typeText` 1 raise + 2 posts; `scroll` 1 raise + 2 posts; `setValue`/`performSecondaryAction`/`selectText` 1 raise each; `drag` 1 raise + 3 posts.)

- [ ] **Step 4: Add the wire field**

`Sources/SkylightCore/Protocol/APITypes.swift`: to each of `ClickInput`, `PressKeyInput`, `TypeTextInput`, `ScrollInput`, `SetValueInput`, `DragInput`, `PerformSecondaryActionInput`, `SelectTextInput` add:

```swift
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (SKYLIGHT_BACKGROUND).
    public let background: Bool?
```

and append `background: Bool? = nil` as the LAST init parameter with `self.background = background` (last position keeps existing positional call sites compiling). Example, `ClickInput`:

```swift
public struct ClickInput: Codable, Equatable {
    public let app: String
    public let element_index: Int?
    public let x: Double?
    public let y: Double?
    public let mouse_button: String?   // "left" | "right" | "middle"
    public let click_count: Int?
    /// Per-request background override: true = never activate / post per-pid,
    /// false = force activation, absent = daemon default (SKYLIGHT_BACKGROUND).
    public let background: Bool?
    public init(app: String, element_index: Int? = nil, x: Double? = nil, y: Double? = nil,
                mouse_button: String? = nil, click_count: Int? = nil, background: Bool? = nil) {
        self.app = app
        self.element_index = element_index
        self.x = x
        self.y = y
        self.mouse_button = mouse_button
        self.click_count = click_count
        self.background = background
    }
}
```

`ts/src/types.ts`: add to the same 8 input interfaces:

```typescript
  /** Per-request background override: true = act without stealing focus (AX-index actions reliable; coordinates/keys best-effort). Absent = daemon default. */
  background?: boolean;
```

`contracts/fixtures.json` — in `requests`, after the first `click` fixture, add:

```json
    { "method": "click", "params": { "app": "Notes", "element_index": 12, "background": true }, "line": "{\"id\":1,\"method\":\"click\",\"params\":{\"app\":\"Notes\",\"element_index\":12,\"background\":true}}" },
```

- [ ] **Step 5: Run everything** — `swift test`, warning grep, `npx vitest run`. All green.

- [ ] **Step 6: Live check** — a background click must not steal focus from the terminal:

```bash
scripts/skylight-run -e '
await sky.get_app_state({ app: "Finder", disableDiff: true });
const before = (await sky.list_apps()).apps.find(a => a.is_frontmost)?.name;
await sky.click({ app: "Finder", element_index: 0, background: true }).catch(e => console.log("click:", e.code));
const after = (await sky.list_apps()).apps.find(a => a.is_frontmost)?.name;
console.log("frontmost before:", before, "| after:", after, "| focus stolen:", before !== after);'
```

Expected: `focus stolen: false` (element 0 may be non-actionable — the click error is fine; the assertion is about focus).

- [ ] **Step 7: Commit**

```bash
git add Sources/SkylightCore contracts/fixtures.json Tests/SkylightCoreTests/ActuatorTests.swift ts/src/types.ts
git commit -m "feat: per-request background override on all actions"
```

---

### Task 5: per-app approval allowlist

Opt-in actuation gate, modeled on Sky's per-app approvals. Config file `~/Library/Application Support/skylight/approvals.json`: `{"mode": "allow_all" | "allowlist", "allow": ["TextEdit", "com.apple.TextEdit", "*"]}`. Missing/unreadable file = allow_all (nothing breaks until the user opts in). Gates the 8 actuation methods only — `get_app_state`/`list_*` stay open (reading is how a model decides what to ask approval for). Matching is case-insensitive against app name and bundle id. New error code `approval_required`. `skylight` CLI manages the file.

**Files:**
- Create: `Sources/SkylightCore/Approvals.swift`
- Create: `Tests/SkylightCoreTests/ApprovalsTests.swift`
- Modify: `Sources/SkylightCore/Protocol/Messages.swift:37-50` (error code)
- Modify: `Sources/SkylightCore/Paths.swift` (approvalsFile)
- Modify: `Sources/SkylightCore/Actuation/Actuator.swift` (gate)
- Modify: `Sources/SkylightService/main.swift` (inject)
- Modify: `Sources/skylight/main.swift` (CLI subcommands)

**Interfaces:**
- Produces: `Approvals(fileURL:)` with `load() -> ApprovalsConfig`, `check(name:bundleID:) throws`, static `isAllowed(config:name:bundleID:) -> Bool`; `SkylightPaths.approvalsFile: URL`; `SkyErrorCode.approvalRequired` (= `"approval_required"`); `Actuator.init` gains `approvals: Approvals = Approvals()`.

- [ ] **Step 1: Write the failing tests** — create `Tests/SkylightCoreTests/ApprovalsTests.swift`:

```swift
import XCTest
@testable import SkylightCore

final class ApprovalsTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-\(UUID().uuidString).json")
    }

    func testMissingFileMeansAllowAll() {
        let approvals = Approvals(fileURL: tempFile()) // never written
        XCTAssertEqual(approvals.load(), ApprovalsConfig(mode: "allow_all", allow: []))
        XCTAssertNoThrow(try approvals.check(name: "TextEdit", bundleID: "com.apple.TextEdit"))
    }

    func testAllowlistMatchingIsCaseInsensitiveOnNameAndBundleID() {
        let cfg = ApprovalsConfig(mode: "allowlist", allow: ["textedit", "COM.APPLE.FINDER"])
        XCTAssertTrue(Approvals.isAllowed(config: cfg, name: "TextEdit", bundleID: nil))
        XCTAssertTrue(Approvals.isAllowed(config: cfg, name: "Finder", bundleID: "com.apple.finder"))
        XCTAssertFalse(Approvals.isAllowed(config: cfg, name: "Safari", bundleID: "com.apple.Safari"))
        XCTAssertTrue(Approvals.isAllowed(config: ApprovalsConfig(mode: "allowlist", allow: ["*"]),
                                          name: "Anything", bundleID: nil))
    }

    func testCheckThrowsApprovalRequiredForUnlistedApp() throws {
        let url = tempFile()
        let cfg = ApprovalsConfig(mode: "allowlist", allow: ["TextEdit"])
        try JSONEncoder().encode(cfg).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let approvals = Approvals(fileURL: url)
        XCTAssertNoThrow(try approvals.check(name: "TextEdit", bundleID: nil))
        XCTAssertThrowsError(try approvals.check(name: "Safari", bundleID: "com.apple.Safari")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .approvalRequired)
        }
    }

    func testMalformedFileFailsOpenToAllowAll() throws {
        let url = tempFile()
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try Approvals(fileURL: url).check(name: "Safari", bundleID: nil))
    }
}
```

- [ ] **Step 2: Run — expect compile FAILURE**: `swift test --filter ApprovalsTests 2>&1 | tail -3`

- [ ] **Step 3: Implement**

`Sources/SkylightCore/Protocol/Messages.swift` — add to `SkyErrorCode`:

```swift
    case approvalRequired = "approval_required"
```

`Sources/SkylightCore/Paths.swift` — add to `SkylightPaths`:

```swift
    /// Per-app actuation allowlist; absent file = allow_all (opt-in gate).
    public static var approvalsFile: URL {
        supportDir.appendingPathComponent("approvals.json")
    }
```

Create `Sources/SkylightCore/Approvals.swift`:

```swift
import Foundation

public struct ApprovalsConfig: Codable, Equatable {
    /// "allow_all" (default) or "allowlist".
    public var mode: String
    /// App names and/or bundle ids (case-insensitive); "*" allows everything.
    public var allow: [String]
    public init(mode: String, allow: [String]) {
        self.mode = mode
        self.allow = allow
    }
}

/// Per-app actuation gate, modeled on Sky's per-app approvals. Fails OPEN on a
/// missing or malformed file (allow_all): the gate is opt-in, and a corrupt
/// config must not brick every action for a personal tool. Reloaded on every
/// check so edits (or `skylight approve`) apply without a daemon restart.
public struct Approvals {
    public let fileURL: URL

    public init(fileURL: URL = SkylightPaths.approvalsFile) {
        self.fileURL = fileURL
    }

    public func load() -> ApprovalsConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(ApprovalsConfig.self, from: data) else {
            return ApprovalsConfig(mode: "allow_all", allow: [])
        }
        return cfg
    }

    public static func isAllowed(config: ApprovalsConfig, name: String?, bundleID: String?) -> Bool {
        guard config.mode == "allowlist" else { return true }
        let allowed = Set(config.allow.map { $0.lowercased() })
        if allowed.contains("*") { return true }
        return [name, bundleID].compactMap { $0?.lowercased() }.contains { allowed.contains($0) }
    }

    public func check(name: String?, bundleID: String?) throws {
        guard Approvals.isAllowed(config: load(), name: name, bundleID: bundleID) else {
            let label = name ?? bundleID ?? "app"
            throw SkyServiceError(code: .approvalRequired,
                message: "'\(label)' is not approved for actuation — run 'skylight approve \"\(label)\"' or edit \(fileURL.path)")
        }
    }
}
```

`Sources/SkylightCore/Actuation/Actuator.swift`:
- Add stored property `private let approvals: Approvals` and init parameter `approvals: Approvals = Approvals()` (assign in init).
- Add helper after `guardNotPaused()`:

```swift
    /// Resolve + approval-gate in one step; every action targets apps only
    /// through this, so the allowlist cannot be bypassed.
    private func resolveApproved(_ identifier: String) throws -> NSRunningApplication {
        let app = try registry.resolve(identifier)
        try approvals.check(name: app.localizedName, bundleID: app.bundleIdentifier)
        return app
    }
```

- Replace EVERY `try registry.resolve(...)` inside Actuator with `try resolveApproved(...)` — sites: `target(_:needsGeometry:)` (line ~113), `click` element branch, `scroll`, `setValue`, `performSecondaryAction`, `selectText`. (`grep -n "registry.resolve" Sources/SkylightCore/Actuation/Actuator.swift` afterward must show zero hits.)

`Sources/SkylightService/main.swift` — pass an explicit instance (line ~28):

```swift
let actuator = Actuator(registry: registry, capture: axCapture,
                        postActionSleepMs: postActionSleepMs, background: background,
                        approvals: Approvals())
```

- [ ] **Step 4: Add an Actuator-level gate test** to `Tests/SkylightCoreTests/ActuatorTests.swift` (Finder is always running, and both resolve + approval-check happen before any AX/TCC-dependent call):

```swift
    func testActuationBlockedByApprovalsAllowlist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-gate-\(UUID().uuidString).json")
        try JSONEncoder().encode(ApprovalsConfig(mode: "allowlist", allow: ["SomeOtherApp"])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let actuator = Actuator(registry: AppRegistry(), capture: AXCapture(),
                                approvals: Approvals(fileURL: url))
        XCTAssertThrowsError(try actuator.typeText(TypeTextInput(app: "Finder", text: "x"))) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .approvalRequired)
        }
    }
```

(If the existing ActuatorTests constructor passes `pauseFile:`, mirror that here so the pause sentinel from other tests can't interfere.)

- [ ] **Step 5: CLI subcommands** — in `Sources/skylight/main.swift`, add functions and switch cases:

```swift
func showApprovals() {
    let approvals = Approvals()
    let cfg = approvals.load()
    print("approvals file: \(approvals.fileURL.path)")
    print("mode: \(cfg.mode)")
    for entry in cfg.allow { print("  allow: \(entry)") }
    if cfg.mode != "allowlist" {
        print("  (allow_all: every app may be actuated; 'skylight approve <app>' to lock down)")
    }
}

func approve(_ name: String) {
    let approvals = Approvals()
    var cfg = approvals.load()
    cfg.mode = "allowlist"
    if !cfg.allow.contains(where: { $0.lowercased() == name.lowercased() }) {
        cfg.allow.append(name)
    }
    writeApprovals(cfg, to: approvals.fileURL)
    print("approved '\(name)'; mode=allowlist (\(cfg.allow.count) app(s) allowed)")
}

func allowAll() {
    let approvals = Approvals()
    writeApprovals(ApprovalsConfig(mode: "allow_all", allow: []), to: approvals.fileURL)
    print("approvals reset: allow_all")
}

func writeApprovals(_ cfg: ApprovalsConfig, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cfg).write(to: url)
    } catch {
        print("error: cannot write \(url.path): \(error)")
        exit(1)
    }
}
```

Update the command switch:

```swift
switch CommandLine.arguments.dropFirst().first {
case "doctor": doctor()
case "start": start()
case "usage": usage()
case "approvals": showApprovals()
case "approve":
    guard let name = CommandLine.arguments.dropFirst(2).first else {
        print("usage: skylight approve <app-name-or-bundle-id>")
        exit(2)
    }
    approve(name)
case "allow-all": allowAll()
default:
    print("usage: skylight <start|doctor|usage|approvals|approve <app>|allow-all>")
    exit(2)
}
```

- [ ] **Step 6: Run everything** — `swift test`, warning grep, `npx vitest run`. All green.

- [ ] **Step 7: Live check** (uses the REAL approvals file — restore allow_all after):

```bash
.build/debug/skylight approve TextEdit
scripts/skylight-run -e '
const r1 = await sky.type_text({ app: "Finder", text: "x" }).then(() => "ALLOWED", e => e.code);
const r2 = await sky.type_text({ app: "TextEdit", text: "" }).then(() => "allowed", e => e.code);
console.log("Finder (unlisted):", r1, "| TextEdit (approved):", r2);'
.build/debug/skylight allow-all
```

Expected: `Finder (unlisted): approval_required`; TextEdit anything but approval_required.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests contracts 2>/dev/null; git add Sources/SkylightCore/Approvals.swift Tests/SkylightCoreTests/ApprovalsTests.swift
git commit -m "feat: opt-in per-app approval allowlist gating actuation (approval_required)"
```

---

### Task 6: docs, d.ts regeneration, skill update, end-to-end verification

**Files:**
- Modify: `ts/sky.d.ts` (regenerated, not hand-edited)
- Modify: `CLAUDE.md` (API methods + conventions)
- Modify: `Sources/skylight/main.swift` (usage text)
- Modify: `~/.claude/skills/skylight/SKILL.md` (outside the repo)

**Interfaces:** none produced; consumes everything above.

- [ ] **Step 1: Regenerate the model-facing declarations**

```bash
cd ts && npm run build:dts && git diff --stat sky.d.ts
```

Expected: sky.d.ts now shows `list_windows`, `WindowInfo`, optional `screenshot`, `background`, `window_id`.

- [ ] **Step 2: Update `CLAUDE.md`** — in the "API methods" section, replace the method list sentence with:

```markdown
`list_apps`, `list_windows` (per-app windows with CGWindowIDs), `get_app_state`
(AX text + screenshot; diffs by default, `disableDiff` forces full; `window_id`
targets a non-focused window; degrades to AX-only + `screenshot_error` when the
screenshot fails), `click` (element_index OR x/y), `press_key`, `type_text`,
`scroll`, `set_value`, `drag`, `perform_secondary_action`, `select_text`, plus
`ping`/`echo`. Every action takes optional `background: true` (per-request
no-focus-steal override). Actuation is gated by the opt-in per-app allowlist in
`~/Library/Application Support/skylight/approvals.json` (`skylight approve`);
unlisted apps fail `approval_required`. See `ts/sky.d.ts`.
```

- [ ] **Step 3: Update the `usage()` text in `Sources/skylight/main.swift`** — replace the "Background mode:" paragraph with:

```
    Background mode: pass background: true on any action to act without stealing
    focus (reliable for element_index actions; best-effort for coordinate clicks
    and keyboard — menu shortcuts like Cmd+c need frontmost). Or start the daemon
    with SKYLIGHT_BACKGROUND=1 to make that the default.

    Approvals: 'skylight approve <app>' switches actuation to an allowlist
    ('skylight approvals' to inspect, 'skylight allow-all' to reset). Unlisted
    apps fail with approval_required.
```

- [ ] **Step 4: Update the skill** at `/Users/baileywickham/.claude/skills/skylight/SKILL.md`:

In the API quick reference table: add row `| list_windows | — (windows with window_id, title, is_focused) |` after `list_apps`; change get_app_state row to `` `disableDiff?`, `window_id?` (from list_windows), `include_data_url?` ``; add to the click/press_key/type_text/etc. description that every action accepts `background?: true`.

In Workflow step 1, change the screenshot mention to: "screenshot (`s.screenshot?.url` — may be absent with `s.screenshot_error` set when Screen Recording is ungranted; the AX text still works)."

Replace the focus-stealing gotcha bullet with:

```markdown
- Actions activate the target app (steals focus) by default. Pass `background: true` on any action to act without stealing focus — reliable for `element_index` actions, best-effort for coordinates/keys (menu shortcuts need frontmost).
- If an action fails `approval_required`: the actuation allowlist is on — `skylight approve "<App>"` (binary: `~/workspace/skylight/.build/debug/skylight`), or `skylight allow-all` to disable the gate.
```

Add a new section before Gotchas:

```markdown
## Per-app notes

- **Chrome / browsers**: the tab strip is NOT in the AX tree — the window title tells you the active tab; `list_windows` enumerates windows (per profile). For tab-level work prefer the claude-in-chrome browser tools; Skylight is for the native chrome (dialogs, menus, settings).
- **Chromium/Electron apps** (Slack, Obsidian, Notion, VS Code): first capture is slow (up to ~3s) while accessibility enablement settles; subsequent captures are fast. If the tree looks empty, re-capture once.
- **Finder**: the desktop belongs to Finder — its tree often starts with the desktop scroll area, not a window. Use `list_windows` + `window_id` to target an actual Finder window.
- **Multi-window apps**: `get_app_state` defaults to the focused window. When the user says "this window", check `list_windows` and pick by `is_focused` / title.
```

- [ ] **Step 5: Full verification**

```bash
swift build 2>&1 | grep -i warning        # empty
swift test 2>&1 | grep -E "Executed .* tests"   # 0 failures
(cd ts && npx vitest run)                  # all pass
```

Restart the live daemon on the new binary and run one combined driver:

```bash
scripts/skylight-run --stop && swift build
scripts/skylight-run -e '
const wins = await sky.list_windows({ app: "Finder" });
console.log("windows:", wins.windows.length);
const s = await sky.get_app_state({ app: "Finder", disableDiff: true });
console.log("screenshot present:", s.screenshot != null, "| error:", s.screenshot_error ?? "none");
await sky.click({ app: "Finder", element_index: 0, background: true }).catch(e => console.log("bg click:", e.code));
console.log("OK");'
```

- [ ] **Step 6: Commit**

```bash
git add ts/sky.d.ts CLAUDE.md Sources/skylight/main.swift
git commit -m "docs: sky-parity API surface (list_windows, window_id, background, approvals)"
```

(The skill file lives outside the repo — no commit needed for it.)

---

## Self-review notes

- **Spec coverage:** F1 (multi-window) → Tasks 2+3; F2 (per-request background) → Task 4; F3 (AX-only fallback) → Task 1; F4 (approvals) → Task 5; F5 (skill notes) → Task 6. ✔
- **Type consistency:** `WindowInfo.window_id: Int?` (Swift) ↔ `window_id?: number|null` (TS); `capture(app:windowID:disableDiff:)` matches Task 3's daemon call; `effectiveBackground` used only within Actuator + tests; `ApprovalsConfig(mode:allow:)` shared by Task 5's core, tests, and CLI. ✔
- **Ordering constraint:** Task 3 depends on Task 2 (`windowListings`); Task 6 depends on all. Tasks 1, 4, 5 are order-independent among themselves but all touch `APITypes.swift`/`fixtures.json` — execute sequentially, never in parallel worktrees.
- **Known live-test caveat:** Task 4/5/6 live checks actuate real apps (Finder/TextEdit). Run them when the user isn't mid-interaction; all are non-destructive (typing into Finder has no text target; TextEdit types an empty string).
