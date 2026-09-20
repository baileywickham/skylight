/**
 * Live verification for `hover`. Not part of the suite — run by hand against a
 * daemon built from this branch, with a browser the check drives itself.
 *
 * The claim under test: a background hover makes web content render a control
 * that does not exist until the pointer is over it, WITHOUT moving the user's
 * real cursor — so the control gets an element_index and becomes clickable.
 * Before this, such a control was unreachable from a background agent: no AX
 * node to press, and a pixel click at its spot hits the row behind it.
 *
 * Unit tests cannot prove any of it: it needs a real Chromium compositor
 * deciding whether a synthetic per-pid mouse move counts as a hover.
 *
 *   cd ts && npx tsx live/hover-check.mts ["Google Chrome"]
 *
 * Expect HOVER-SEEN PASS, REVEALED-ELEMENT PASS and CLICKED-REVEALED PASS.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { sky } from "../src/index.js";

const app = process.argv[2] ?? "Google Chrome";

// A row whose action button is CREATED on mouseenter and destroyed on
// mouseleave — how claude.ai's routines dialog behaves, and the reason an
// opacity-based fixture would not test anything (an invisible element is still
// in the AX tree).
const page = `<!doctype html><meta charset="utf-8"><title>skylight hover check</title>
<style>body{font:28px/2 -apple-system,sans-serif;padding:60px}
.row{border:2px solid #999;padding:18px 24px;width:640px;display:flex;justify-content:space-between}</style>
<div class="row" id="row"><span>Default</span></div><p id="log">no hover yet</p>
<script>
const row=document.getElementById("row"),log=document.getElementById("log");
row.addEventListener("mouseenter",()=>{log.textContent="HOVER SEEN by the page";
  if(!document.getElementById("edit")){const b=document.createElement("button");
    b.id="edit";b.textContent="Edit cloud environment";
    b.addEventListener("click",()=>log.textContent="BUTTON CLICKED");row.appendChild(b);}});
row.addEventListener("mouseleave",()=>{log.textContent="hover left";
  document.getElementById("edit")?.remove();});
</script>`;

const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "skylight-hover-")), "hover.html");
fs.writeFileSync(file, page);
execFileSync("/usr/bin/open", ["-a", app, `file://${file}`]);
await new Promise((r) => setTimeout(r, 3000));

const tree = async () => (await sky.get_app_state({ app, disableDiff: true, include_data_url: false })).text;
const lineFor = (t: string, re: RegExp) => t.split("\n").map((l) => l.trim()).find((l) => re.test(l));
const indexOf = (t: string, re: RegExp) => {
  const line = lineFor(t, re);
  return line ? Number(line.match(/\[(\d+)\]/)![1]) : null;
};
const status = (t: string) => lineFor(t, /no hover yet|HOVER SEEN|hover left|BUTTON CLICKED/) ?? "(none)";

// Case A needs the browser frontmost. Say so outright: run straight after
// another live check and `open -a` may hand the fixture to a window that is not
// key, which used to surface as a bare FAIL that looked like a regression.
const frontNow = execFileSync("/usr/bin/osascript",
  ["-e", 'tell application "System Events" to return name of first application process whose frontmost is true'])
  .toString().trim();
if (frontNow !== app) {
  throw new Error(`${app} is not frontmost (${frontNow} is) — the first leg tests the frontmost case. `
    + "Close stray test tabs and rerun; the background leg below covers the other case.");
}

const before = await tree();
console.log("BASELINE", status(before));
if (indexOf(before, /Edit cloud environment/) != null) {
  throw new Error("the control is already present — the real cursor is parked on the row; move it away");
}

const row = indexOf(before, /value="Default"/);
if (row == null) throw new Error("fixture row not found; is the page the frontmost tab?");
await sky.hover({ app, element_index: row, settle_ms: 600 });

const after = await tree();
console.log("AFTER-HOVER", status(after));
console.log(/HOVER SEEN/.test(status(after)) ? "HOVER-SEEN PASS" : "HOVER-SEEN FAIL");

const revealed = indexOf(after, /Edit cloud environment/);
console.log(revealed != null ? `REVEALED-ELEMENT PASS (index ${revealed})` : "REVEALED-ELEMENT FAIL");

if (revealed != null) {
  await sky.click({ app, element_index: revealed });
  const clicked = status(await tree());
  console.log("AFTER-CLICK", clicked);
  console.log(/BUTTON CLICKED/.test(clicked) ? "CLICKED-REVEALED PASS" : "CLICKED-REVEALED FAIL");
}

// The case that matters and that this check used to miss: the browser is NOT
// the frontmost app. A pointer move only produces :hover in Chromium while the
// target is ACTIVE, so without the focus-without-raise flip this silently does
// nothing — which is how `hover` shipped in v0.3.5, working only when the user
// happened to be looking at the browser.
execFileSync("/usr/bin/osascript", ["-e", 'tell application "Finder" to activate']);
await new Promise((r) => setTimeout(r, 1200));
await sky.hover({ app, x: 5, y: 5 });          // park the pointer off the row
await new Promise((r) => setTimeout(r, 400));
const backgroundBaseline = await tree();
if (indexOf(backgroundBaseline, /Edit cloud environment/) != null) {
  throw new Error("the control is still present; the pointer did not leave the row");
}
const rowAgain = indexOf(backgroundBaseline, /value="Default"/)!;
await sky.hover({ app, element_index: rowAgain, settle_ms: 700 });
const backgrounded = await tree();
const front = execFileSync("/usr/bin/osascript",
  ["-e", 'tell application "System Events" to return name of first application process whose frontmost is true'])
  .toString().trim();
console.log("BACKGROUND-HOVER", status(backgrounded), `(frontmost: ${front})`);
console.log(indexOf(backgrounded, /Edit cloud environment/) != null && front !== app
  ? "BACKGROUND-HOVER PASS"
  : "BACKGROUND-HOVER FAIL");

sky.close();
