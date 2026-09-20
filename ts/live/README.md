# Live checks

Manual verification for behavior that unit tests structurally cannot prove: the
private window-server records in `SkyLightBridge` are accepted (or silently
ignored) only by a real window server, per-app parallelism is only observable
through a real socket with real timing, and only a real Chromium compositor
decides whether a synthetic mouse move counts as a hover.

Run these after a macOS upgrade, or when `skylight doctor` reports
`focus w/o raise: UNAVAILABLE`. They need a daemon built from the current tree:

```bash
swift build && pkill -TERM -f '.build/debug/SkylightService'
(nohup .build/debug/SkylightService >/tmp/skylight.log 2>&1 &)
```

## background-check.mts

Proves a menu key equivalent fires in an app that is **not** frontmost, and that
firing it does not steal focus. This is the whole point of focus-without-raise:
before it, a background `Cmd+c` reached nobody, because the menu bar belongs to
the frontmost app.

```bash
echo "marker-123" > /tmp/skylight-live.txt
open -a TextEdit /tmp/skylight-live.txt
osascript -e 'tell application "Finder" to activate'   # TextEdit must be BACKGROUND
cd ts && pnpm exec tsx live/background-check.mts marker-123
```

Expect `COPIED-IN-BACKGROUND PASS` and `KEPT-FOCUS PASS`.

## parallel-check.mts

Proves background actions against different apps overlap, while two against one
app still serialize. Uses empty `type_text` calls: they post no keystrokes, so
nothing is modified, but they pay the full post-action settle that makes the
overlap measurable.

```bash
cd ts && pnpm exec tsx live/parallel-check.mts TextEdit Finder
```

Expect roughly a 2x `SPEEDUP`, `DIFFERENT-APPS-OVERLAP PASS`, and
`SAME-APP-SERIALIZED PASS`.

## hover-check.mts

Proves a background `hover` makes web content render a control that exists only
while the pointer is over it — with the user's real cursor untouched — so the
control gets an `element_index` and can be clicked. Before `hover`, a control
like that was unreachable from a background agent. The check writes its own
fixture page and opens it; keep the real cursor off the page while it runs, and
leave the fixture window as the browser's key window — a hover into a
non-key window is dropped by the browser and the check will (correctly) fail.

```bash
cd ts && pnpm exec tsx live/hover-check.mts "Google Chrome"
```

Expect `HOVER-SEEN PASS`, `REVEALED-ELEMENT PASS` and `CLICKED-REVEALED PASS`.

## fixes-check.mts

Covers the four 2026-09-19 fixes in one pass against a throwaway page it opens
itself: `type_text` with an `element_index` lands in the named field (never
focused beforehand), `press_key` with `repeat` sends the chord N times,
`set_value` errors on a controlled React input that discards the write while
still accepting a normal one, and `get_app_state` with `root_element_index`
returns a pane-sized tree whose diff stays `(no changes)` while a second pane
keeps ticking. Expect five PASS lines.

```bash
cd ts && npx tsx live/fixes-check.mts "Google Chrome"
```

Assertions track fields by sticky `element_index`, not by label: a node prints
its label or its value, so a labelled field stops matching its label as soon as
it holds text.
