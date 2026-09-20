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
 * Expect six PASS lines and no FAIL.
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
<div id="target" aria-label="click target" style="height:70vh;background:#eef;border:1px solid #88a">clicks: 0</div>
<script>
let clicks = 0;
document.getElementById("target").addEventListener("click", () => {
  document.getElementById("target").textContent = "clicks: " + (++clicks);
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
const frontBefore = frontmost();
const shot = (await sky.get_app_state({ app, disableDiff: true, include_data_url: false })).screenshot;
if (shot == null) throw new Error("no screenshot: coordinate clicks need capture geometry");
const before = lineFor(await full(), /clicks: \d+/) ?? "";
// Aim at the middle of the page, not near an element's edge: a few pixels
// past the target reads as "the click did not land".
await sky.click({ app, x: shot.width / 2, y: shot.height * 0.6 });
const after = lineFor(await full(), /clicks: \d+/) ?? "";
const frontAfter = frontmost();
check("background coordinate click lands",
  before !== after && /clicks: [1-9]/.test(after),
  `${before.trim() || "(none)"} -> ${after.trim() || "(none)"}`);
check("background click did not steal focus",
  frontBefore !== app && frontAfter === frontBefore, `${frontBefore} -> ${frontAfter}`);

sky.close();
