# Background & parallel agents

Status: design approved 2026-08-05.

Skylight today is **foreground-first**: every action activates the target app,
raises its window, and drives it with the real cursor. `SKYLIGHT_BACKGROUND=1`
exists but is explicitly best-effort — menu key equivalents (Cmd+C) usually do
not fire in a non-frontmost app, and Chromium/Electron apps mishandle input
received while inactive. One global serial actuation queue means one action at
a time, machine-wide.

This spec closes both gaps: background mode becomes *reliable*, and actions
against **different apps** run **concurrently**.

## Background

The technique is public. OpenAI's Codex desktop app (April 2026) drives
backgrounded macOS apps by decoupling three things macOS normally couples: an
app being AppKit-*active* (receives input), its window being *raised* (z-order),
and the *cursor* moving. The cua team reverse-engineered it
([Inside macOS window internals](https://cua.ai/blog/inside-macos-window-internals));
the underlying focus-without-raise trick has been in yabai for years.

There is no OS-level multi-cursor. "Each agent gets its own cursor" is cosmetic:
events are routed per-pid, so no cursor needs to move at all. Parallelism falls
out of per-pid routing — which is why Codex allows concurrent agents on
*different* apps but forbids two on the same app.

## Goals

1. Background actions land as reliably as foreground ones, including menu key
   equivalents.
2. Actions against different apps run concurrently.
3. Never crash and never regress today's behavior when private symbols are
   unavailable.

## Non-goals

- A drawn overlay cursor (cosmetic; skylight has no UI layer).
- Virtual displays or VMs. They solve *visual* separation, not input routing,
  and would not remove the need for the SkyLight work.
- Concurrency for two requests against the *same* app. Serialized, as in Codex.
- Changing the default mode. Foreground stays the default.

## Architecture

Four new units, each independently testable:

```
SkyLightBridge      dlsym-probed private symbols + capability report
EventRecord         pure byte-record builders (no syscalls) — unit-tested
ActuationScheduler  key-based admission control (concurrent per key, exclusive mode)
RequestClass        pure classification: which key, exclusive or not
```

### 1. SkyLightBridge

Follows the precedent already set by `AXWindowBridge` (`_AXUIElementGetWindow`):
`dlsym` at call time, return nil when absent, degrade rather than fail.

Symbols:

| Symbol | Signature bound | Use |
| :-- | :-- | :-- |
| `SLPSPostEventRecordTo` | `(UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError` | deliver the activate/deactivate/key-window records |
| `_SLPSGetFrontProcess` | `(UnsafeMutablePointer<ProcessSerialNumber>) -> CGError` | the psn to deactivate |
| `GetProcessForPID` | `(pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus` | pid → psn (deprecated Carbon; dlsym'd to keep the build warning-free) |

`SkyLightCapabilities` reports which resolved, surfaced through a new
`capabilities` API method and `skylight doctor`.

**`SLEventPostToPid` is deliberately excluded from the default path.** Its exact
signature is not documented anywhere we can verify, and a wrong `@convention(c)`
binding crashes rather than degrading — which violates goal 3. It sits behind
`SKYLIGHT_TRUSTED_EVENTS=1`, documented as experimental. Everything else in this
spec works without it.

### 2. EventRecord

The event records are 0xf8-byte buffers with hardcoded offsets (from yabai).
Building them is pure, so it is unit-tested exactly:

```
activationRecord(windowID:activate:)  [0x04]=0xf8 [0x08]=0x0d [0x8a]=1|2, wid@0x3c
keyWindowRecords(windowID:)           [0x04]=0xf8 [0x08]=0x01|0x02 [0x3a]=0x10,
                                      wid@0x3c, 0xFF×0x10 @0x20
```

Tests assert length, every magic byte offset, little-endian window-id
placement, and the 0xFF run — so a future edit that shifts an offset fails in
CI instead of silently no-op'ing on a live Mac.

### 3. Focus without raise

New `focusWithoutRaise(app:window:)` in `Activation.swift`, called in
**background** mode where `raiseUnlessBackground` is a no-op today:

1. `GetProcessForPID(pid)` → target psn; `_SLPSGetFrontProcess()` → current psn.
2. If they differ: post the deactivate record to the front psn, then the
   activate record to the target psn.
3. Post both key-window records to the target psn.

No `SLPSSetFrontProcessWithOptions`, so the window never raises and no Space
switch occurs. If any symbol is missing, this is a no-op and background mode
behaves exactly as it does today.

This is what makes Cmd+C fire in a backgrounded app: the app now believes it is
active, so its menu bar matches key equivalents.

### 4. Chromium primer click

Chromium gates synthetic input on a user-activation signal. Before a background
coordinate click, post a throwaway down/up pair at `(-1, -1)` — outside every
window, so it cannot hit anything — and the real click follows as a trusted
continuation. Applied only for background coordinate clicks, and only for
Chromium-family bundle ids (Chrome, Edge, Brave, Arc, Electron apps), matched by
a pure, unit-tested predicate. Known limitation, documented not fixed:
Chromium coerces synthetic right-clicks on web content to left-clicks; use
`perform_secondary_action` with `AXShowMenu` instead.

### 5. Concurrency

**Why per-pid is sound:** every piece of mutable capture state in `AXCapture` is
already partitioned by pid (`stateByPid: [pid_t: AppCaptureState]`). Two
requests for different pids touch disjoint state. The only genuinely shared
mutable thing is the dictionary itself, which gets an `NSLock`. `ElementIndexMap`
needs no lock, because two requests for the *same* pid are serialized by the
scheduler.

**`ActuationScheduler`** replaces `IPCServer`'s single serial queue. It is a
readers-writer-ish gate built on `NSCondition` rather than GCD barriers —
barrier blocks do not reliably exclude work arriving via *targeting* queues,
which is exactly the topology we would need.

```
run(class:body:)
  .exclusive     wait until no keys active and no exclusive active
  .keyed(k)      wait until no exclusive active/waiting and k not active
```

Exclusive waiters take priority over new keyed work, so foreground requests
cannot starve.

**Classification** (`RequestClass`) is a pure function of method, resolved app
key, and effective background flag:

| Request | Class | Why |
| :-- | :-- | :-- |
| `ping`, `echo`, `list_apps` | `.keyed("$meta")` | touch no app state |
| `get_app_state`, `list_windows` | `.keyed(pid)` | capture never activates; per-app state |
| action, background | `.keyed(pid)` | per-pid event routing — safe in parallel |
| action, foreground | `.exclusive` | activation and the cursor are global state |

Foreground therefore behaves exactly as today (fully serialized); parallelism is
a property of background mode only. The app identifier is resolved to a pid
*before* dispatch so that `"Notes"` and `"com.apple.Notes"` cannot get two
queues for one app; unresolvable identifiers fall back to the raw string and the
handler produces the normal `app_not_found` error.

`IPCServer` gains an injected `classify:` closure defaulting to `.exclusive`
for everything — so existing behavior and existing tests are preserved
unchanged.

### 6. Occluded-window AX robustness

`AXManualAccessibility`/`AXEnhancedUserInterface` are applied once per pid
(`enablementDone`). A Chromium window that is occluded or backgrounded can drop
its web area afterwards, leaving later captures empty. Add a pure
`shouldReapplyEnablement(previouslyHadWebArea:currentHasWebArea:)` and re-apply
when a tree that previously had an `AXWebArea` no longer does.

## Testing

Unit (XCTest, no live apps, must stay green in CI):
- `EventRecord` — every offset, length, endianness.
- `SkyLightBridge` — capability probe shape; nil-symbol path is a no-op.
- `ActuationScheduler` — real threads: two keys overlap; same key serializes;
  exclusive excludes everything; exclusive is not starved.
- `RequestClass` — the classification table above.
- Chromium predicate, `shouldReapplyEnablement` — pure.
- `AXCapture` — concurrent `state(for:)` from many threads (race under TSan).

Contract: new `capabilities` request/response in `contracts/fixtures.json`,
matched by Swift `APITypes` and TS `types.ts`/`sky.d.ts`.

Live (gated, `SKYLIGHT_SMOKE=1`): background Cmd+C in a non-frontmost TextEdit
actually copies — the single behavior this whole spec exists to enable.

## Risks

| Risk | Mitigation |
| :-- | :-- |
| Byte offsets change in a future macOS | Records are unit-pinned; failure is a silent no-op, not a crash. Foreground unaffected. |
| A private symbol disappears | dlsym probe → capability reports false → today's behavior. |
| `SLEventPostToPid` signature wrong | Excluded from the default path; opt-in only. |
| Thread explosion from blocked waiters | Concurrency is bounded by the number of live clients (a handful); documented. |
| Parallel actions confuse a user watching | Only background mode parallelizes, and background mode by definition is not what the user is looking at. |
