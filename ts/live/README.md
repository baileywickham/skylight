# Live checks

Manual verification for behavior that unit tests structurally cannot prove: the
private window-server records in `SkyLightBridge` are accepted (or silently
ignored) only by a real window server, and per-app parallelism is only
observable through a real socket with real timing.

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
cd ts && npx tsx live/background-check.mts marker-123
```

Expect `COPIED-IN-BACKGROUND PASS` and `KEPT-FOCUS PASS`.

## parallel-check.mts

Proves background actions against different apps overlap, while two against one
app still serialize. Uses empty `type_text` calls: they post no keystrokes, so
nothing is modified, but they pay the full post-action settle that makes the
overlap measurable.

```bash
cd ts && npx tsx live/parallel-check.mts TextEdit Finder
```

Expect roughly a 2x `SPEEDUP`, `DIFFERENT-APPS-OVERLAP PASS`, and
`SAME-APP-SERIALIZED PASS`.
