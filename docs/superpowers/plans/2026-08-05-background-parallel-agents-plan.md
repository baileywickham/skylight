# Implementation plan — background & parallel agents

Spec: `docs/superpowers/specs/2026-08-05-background-parallel-agents-design.md`

Each task is TDD: write the failing test, implement, keep `swift build` at zero
warnings and `swift test` green.

## Task 1 — EventRecord (pure)

`Sources/SkylightCore/Actuation/EventRecord.swift`

- `activationRecord(windowID:activate:) -> [UInt8]`
- `keyWindowRecords(windowID:) -> [[UInt8]]`

Tests (`EventRecordTests.swift`): length 0xf8; `[0x04]==0xf8`; activation
`[0x08]==0x0d`, `[0x8a]==1` when activate else `2`; key-window pair
`[0x08]==0x01`/`0x02` with `[0x3a]==0x10` and 0xFF×0x10 at 0x20; window id
little-endian at 0x3c; all other bytes zero.

## Task 2 — SkyLightBridge

`Sources/SkylightCore/Actuation/SkyLightBridge.swift`

- dlsym `SLPSPostEventRecordTo`, `_SLPSGetFrontProcess`, `GetProcessForPID`.
- `SkyLightCapabilities { focus_without_raise: Bool, trusted_events: Bool }`
- `postEventRecord(_:to:) -> Bool`, `frontProcess() -> ProcessSerialNumber?`,
  `processSerialNumber(forPid:) -> ProcessSerialNumber?` — each nil/false when
  the symbol is missing.
- Symbols resolved once (lazy static), not per call.

Tests: capabilities probe returns without crashing; the struct is Codable and
round-trips.

## Task 3 — focusWithoutRaise

`Sources/SkylightCore/Actuation/Activation.swift`

- `focusWithoutRaise(app:window:) -> Bool` — deactivate front psn, activate
  target psn, then both key-window records. Returns false if unavailable.
- `Actuator.raiseUnlessBackground` → `prepareTarget`: foreground activates as
  today; background calls `focusWithoutRaise`.

Tests: pure step-sequence helper `focusRecords(targetWindowID:frontIsTarget:)`
returns the right records in the right order for both branches.

## Task 4 — Chromium primer click

`Sources/SkylightCore/Actuation/Activation.swift`

- `needsUserActivationPrimer(bundleID:) -> Bool` — Chromium family.
- `Actuator.click`: background + coordinates + Chromium → primer down/up at
  `(-1,-1)` posted to the pid before the real click.

Tests: predicate table (Chrome/Edge/Brave/Arc/Electron → true; Safari, TextEdit,
nil → false).

## Task 5 — ActuationScheduler

`Sources/SkylightCore/IPC/ActuationScheduler.swift`

- `enum RequestClass { case exclusive; case keyed(String) }`
- `ActuationScheduler.run<T>(_ class: RequestClass, _ body: () throws -> T) rethrows -> T`
- NSCondition; exclusive waiters block new keyed admissions (no starvation).

Tests (real threads, deterministic via semaphores/expectations): two distinct
keys overlap; same key serializes; exclusive runs alone; a waiting exclusive
blocks new keyed work; a throwing body still releases its slot.

## Task 6 — classification

`Sources/SkylightCore/IPC/RequestRouter.swift` (or a new `RequestClassifier.swift`)

- `classify(method:appKey:background:) -> RequestClass` per the spec table.

Tests: the full table, including unknown methods → `.exclusive` (fail safe).

## Task 7 — wire concurrency

- `AXCapture`: `NSLock` around `stateByPid` (all six access points).
- `IPCServer`: `classify: (Request) -> RequestClass` injected, defaulting to
  `{ _ in .exclusive }`; serial queue → concurrent queue + `scheduler.run`.
- `SkylightService/main.swift`: real classifier — decode `app` from params,
  resolve to pid via `AppRegistry` (fall back to the raw string), consult
  `actuator.effectiveBackground`.

Tests: existing `IPCServerTests` must pass untouched (default = exclusive);
new test that two keyed requests overlap through the server.

## Task 8 — occluded-window AX re-enablement

- `shouldReapplyEnablement(previouslyHadWebArea:currentHasWebArea:) -> Bool`
- `AppCaptureState.hadWebArea`; `AXCapture.capture` re-applies and re-walks once.

Tests: pure predicate truth table.

## Task 9 — capabilities API

- `CapabilitiesResult` in `APITypes` (permissions + SkyLight capabilities +
  version), `capabilities` method registered, TS `types.ts`/`sky.d.ts`,
  `contracts/fixtures.json` entry, `skylight doctor` prints the SkyLight rows.

Tests: contract test (Swift + TS) covers the new fixture.

## Task 10 — docs

`CLAUDE.md` (API list, background-mode gotchas, concurrency invariant),
`skill/SKILL.md` (background + parallel usage), spec cross-link.

## Verification

- `swift build 2>&1 | grep -i warning` → empty
- `swift test` → green
- `(cd ts && npx vitest run)` → green
- Gated live check documented for the user to run:
  background Cmd+C into a non-frontmost TextEdit.
