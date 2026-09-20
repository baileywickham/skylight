/**
 * Live verification for the fixes from Bailey's 2026-09-19 list. Not part of
 * the suite — it needs a real Chromium compositor and a real AX tree.
 *
 *   1. type_text element_index   — text lands in the named field, not wherever
 *                                  focus happens to be.
 *   2. set_value read-back       — a controlled input that discards the write
 *                                  is an error, not a silent success.
 *   3. press_key repeat          — one call sends the chord N times.
 *   4. root_element_index        — the tree and the diff cover one pane, so an
 *                                  unrelated webview's churn stays out.
 *   5. background coordinate click — a click posted into a NON-frontmost window
 *                                  actually reaches the page, and the user's
 *                                  frontmost app never changes (see
 *                                  BackgroundMouse; this is the one that used
 *                                  to report done:true and do nothing).
 *
 *   cd ts && npx tsx live/fixes-check.mts ["Google Chrome"]
 *
 * Every line must say PASS.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { SkyError } from "../src/client.js";
import { sky } from "../src/index.js";

const app = process.argv[2] ?? "Google Chrome";

// Two panes: the one under test, and one that changes on its own — the shape
// of an Electron window whose sidebar repaints while you work in the main view.
const page = `<!doctype html><meta charset="utf-8"><title>skylight fixes check</title>
<style>body{font:16px system-ui;padding:40px}section{border:1px dashed #bbb;padding:12px;margin:12px 0}
input{font:16px system-ui;padding:6px;width:320px}</style>
<section aria-label="Work pane">
  <input id="plain" aria-label="Plain field">
  <div id="react-root"></div>
</section>
<!-- Fills the rest of the viewport, so a click aimed at the middle of the
     window lands inside it without the check having to know page geometry. -->
<div id="target" aria-label="click target" style="height:150vh;background:#eef;border:1px solid #88a">clicks: 0</div>
<div id="where" aria-label="click position" style="position:fixed;top:0;right:0;background:#000;color:#0f0;font:13px monospace;padding:4px">no click</div>
<script>
let clicks = 0;
document.getElementById("target").addEventListener("click", (e) => {
  document.getElementById("target").textContent = "clicks: " + (++clicks);
  // WHERE it landed, not just that it landed: a coordinate bug that mirrors
  // the click about the window's midline still increments a counter on a
  // full-height target, and that is exactly how v0.3.7 shipped broken.
  document.getElementById("where").textContent =
    "clientX=" + Math.round(e.clientX) + " clientY=" + Math.round(e.clientY) +
    " innerH=" + window.innerHeight;
});
</script>
<section aria-label="Noisy pane"><div id="tick" aria-label="ticker">tick 0</div></section>
<script>let n=0;setInterval(()=>{document.getElementById("tick").textContent="tick "+(++n);},300);</script>
<script src="https://unpkg.com/react@18/umd/react.production.min.js" crossorigin></script>
<script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js" crossorigin></script>
<script>
const e=React.createElement;
function App(){
  const [v]=React.useState("locked");
  // Controlled and rejecting: AX SetValue succeeds, React re-renders, the old
  // value is back. The exact shape that used to report done:true and change nothing.
  return e("input",{id:"locked","aria-label":"Locked field",value:v,onChange(){}});
}
ReactDOM.createRoot(document.getElementById("react-root")).render(e(App));
</script>`;

const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "skylight-fixes-")), "fixes.html");
fs.writeFileSync(file, page);
execFileSync("/usr/bin/open", ["-a", app, `file://${file}`]);
await new Promise((r) => setTimeout(r, 3500));
// Move the window OFF the display origin. With a window at (0,0), global and
// window-local coordinates are the same number and a whole class of coordinate
// bug — using one where the other belongs — passes unnoticed.
if (app === "Google Chrome") {
  execFileSync("/usr/bin/osascript",
    ["-e", 'tell application "Google Chrome" to set bounds of front window to {140, 110, 1140, 810}']);
  await new Promise((r) => setTimeout(r, 800));
}

const full = async () => (await sky.get_app_state({ app, disableDiff: true, include_data_url: false })).text;
const lineFor = (t: string, re: RegExp) => t.split("\n").map((l) => l.trim()).find((l) => re.test(l));
const indexOf = (t: string, re: RegExp) => {
  const line = lineFor(t, re);
  return line ? Number(line.match(/\[(\d+)\]/)![1]) : null;
};
// Track fields by their sticky index, never by label: the serializer prints a
// node's label OR its value, so a labelled field loses its label the moment it
// has text in it.
const lineAt = (t: string, index: number) => lineFor(t, new RegExp(`^\\[${index}\\] `)) ?? "(gone)";
const check = (name: string, ok: boolean, detail = "") =>
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);

const tree = await full();
const plain = indexOf(tree, /AXTextField "Plain field"/);
const locked = indexOf(tree, /AXTextField.*value="locked"/);
const workPane = indexOf(tree, /AXGroup "Work pane"/);
if (plain == null || locked == null || workPane == null) {
  throw new Error(`fixture not found (plain=${plain} locked=${locked} pane=${workPane}); is the page frontmost?`);
}

// 1. type_text element_index — the field is NOT focused beforehand.
await sky.type_text({ app, element_index: plain, text: "landed-here" });
const afterType = await full();
check("type_text element_index", /value="landed-here"/.test(lineAt(afterType, plain)), lineAt(afterType, plain));

// 2. press_key repeat — five BackSpaces in one call, on the field just focused.
await sky.press_key({ app, keys: "BackSpace", repeat: 5 });
const afterRepeat = await full();
check("press_key repeat", /value="landed"$|value="landed"/.test(lineAt(afterRepeat, plain)), lineAt(afterRepeat, plain));

// 3. set_value on a controlled input that discards the write — must ERROR.
let rejected: string | null = null;
try {
  await sky.set_value({ app, element_index: locked, value: "SHOULD-NOT-STICK" });
} catch (err) {
  rejected = err instanceof SkyError ? err.code : String(err);
}
check("set_value rejects a discarded write", rejected === "element_not_actionable", rejected ?? "no error thrown");

// 4. set_value on a field that does accept writes still succeeds.
const accepted = await sky.set_value({ app, element_index: plain, value: "set-directly" });
check("set_value still accepts a real write", accepted.done === true);

// 5. root_element_index — scoped tree excludes the noisy pane, and two scoped
// captures in a row diff to "(no changes)" while the ticker keeps ticking.
const scoped = await sky.get_app_state({ app, root_element_index: workPane, disableDiff: true, include_data_url: false });
await new Promise((r) => setTimeout(r, 1200)); // several ticks
const scopedDiff = await sky.get_app_state({ app, root_element_index: workPane, include_data_url: false });
check("root_element_index scopes tree and diff",
  !/ticker|tick \d/.test(scoped.text) && !/tick \d/.test(scopedDiff.text),
  `scoped tree ${scoped.text.split("\n").length} lines; diff: ${scopedDiff.text.replace(/\n/g, " | ").slice(0, 120)}`);

// 6. Background coordinate click: another app is frontmost the whole time.
execFileSync("/usr/bin/osascript", ["-e", 'tell application "Finder" to activate']);
await new Promise((r) => setTimeout(r, 1200));
const frontmost = () =>
  execFileSync("/usr/bin/osascript",
    ["-e", 'tell application "System Events" to return name of first application process whose frontmost is true'])
    .toString().trim();
// What the app ITSELF believes. Background actuation flips this to make the
// target active without raising it, and the user's app must be put back: macOS
// still calls it frontmost either way, but the app dims its title bar, stops
// its caret and behaves as if you switched away.
const believesFrontmost = (name: string) =>
  execFileSync("/usr/bin/osascript",
    ["-e", `tell application "System Events" to return frontmost of process "${name}"`])
    .toString().trim() === "true";
const frontBefore = frontmost();
const shot = (await sky.get_app_state({ app, disableDiff: true, include_data_url: false })).screenshot;
if (shot == null) throw new Error("no screenshot: coordinate clicks need capture geometry");
const before = lineFor(await full(), /clicks: \d+/) ?? "";
// Above the window's midline but below the fields at the top of the page, so a
// mirrored click lands ~150pt away instead of passing on a tall target. And off
// centre in x: aiming at width/2 makes an x mirror invisible.
const aimY = shot.height * 0.45;
const aimX = shot.width * 0.32;
await sky.click({ app, x: aimX, y: aimY });
const afterTree = await full();
const after = lineFor(afterTree, /clicks: \d+/) ?? "";
const frontAfter = frontmost();
check("background coordinate click lands",
  before !== after && /clicks: [1-9]/.test(after),
  `${before.trim() || "(none)"} -> ${after.trim() || "(none)"}`);

// Where it landed. The page reports clientY; convert the aim point to the same
// space via the viewport height, and allow for browser chrome above it.
const where = lineFor(afterTree, /clientY=/) ?? "";
const landed = Number(where.match(/clientY=(-?\d+)/)?.[1] ?? NaN);
const innerH = Number(where.match(/innerH=(\d+)/)?.[1] ?? NaN);
const scale = shot.scale ?? 2;
const chromeHeight = shot.height / scale - innerH;   // toolbar + bookmarks, in points
const expected = aimY / scale - chromeHeight;
const landedX = Number(where.match(/clientX=(-?\d+)/)?.[1] ?? NaN);
const expectedX = aimX / scale;
check("background click lands where it was aimed",
  Number.isFinite(landed) && Math.abs(landed - expected) <= 12
    && Number.isFinite(landedX) && Math.abs(landedX - expectedX) <= 12,
  `expected clientX≈${Math.round(expectedX)},clientY≈${Math.round(expected)}; `
  + `got ${landedX},${landed} (y mirrored would be ≈${Math.round(innerH - expected)})`);
check("background click did not steal focus",
  frontBefore !== app && frontAfter === frontBefore, `${frontBefore} -> ${frontAfter}`);
check("the user's app was left believing it is active",
  believesFrontmost(frontBefore),
  `${frontBefore} believes frontmost: ${believesFrontmost(frontBefore)}`);

// 7. The same, in a NATIVE app. This is what the Chromium-only gate wrongly
// refused, so it needs live coverage: a regression here goes straight back to
// "done: true and nothing happens".
const doc = path.join(path.dirname(file), "native.txt");
fs.writeFileSync(doc, "AAAAAAAAAAAAAAAAAAAA\nBBBBBBBBBBBBBBBBBBBB\nCCCCCCCCCCCCCCCCCCCC\n");
execFileSync("/usr/bin/open", ["-a", "TextEdit", doc]);
await new Promise((r) => setTimeout(r, 2500));
execFileSync("/usr/bin/osascript", ["-e", 'tell application "Finder" to activate']);
await new Promise((r) => setTimeout(r, 1200));

const native = async () => (await sky.get_app_state({ app: "TextEdit", disableDiff: true, include_data_url: false }));
const beforeNative = await native();
const nativeScale = beforeNative.screenshot?.scale ?? 1;
// The first text line sits ~40pt below the window top in a default plain-text
// window; aim at its middle, in the pixels of the image just captured.
await sky.click({ app: "TextEdit", x: 60 * nativeScale, y: 40 * nativeScale });
await sky.type_text({ app: "TextEdit", text: "[N]" });
const nativeLine = lineFor((await native()).text, /AXTextArea/) ?? "";
check("background click lands in a native app",
  /A{2,}\[N\]A{2,}/.test(nativeLine),
  nativeLine.slice(0, 90));
check("native click did not steal focus either", frontmost() === frontBefore, frontmost());
check("and still believes it after the native click too", believesFrontmost(frontBefore));

execFileSync("/usr/bin/osascript", ["-e",
  'tell application "TextEdit" to close (every document whose name is "native.txt") saving no']);

sky.close();
