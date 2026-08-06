/**
 * Live verification for background actuation. Not part of the suite — run by
 * hand against a daemon built from this branch.
 *
 * The claim under test: a menu key equivalent (Cmd+a / Cmd+c) fires in an app
 * that is NOT frontmost, and firing it does not steal focus. Before
 * focus-without-raise this failed — the menu bar belongs to the frontmost app,
 * so a background Cmd+c reached nobody.
 */
import { execFileSync } from "node:child_process";
import { sky } from "../src/index.js";

const marker = process.argv[2];
if (!marker) throw new Error("usage: live-background-check.mts <marker>");

const frontmostName = async () => {
  const { apps } = await sky.list_apps();
  return apps.find((a) => a.is_frontmost)?.name ?? "(none)";
};

const caps = await sky.capabilities();
console.log("CAPS", JSON.stringify(caps.skylight), "parallel:", caps.parallel_actuation);

const before = await frontmostName();
console.log("FRONTMOST-BEFORE", before);
if (before === "TextEdit") throw new Error("TextEdit must NOT be frontmost for this test");

// Prime the AX tree so the daemon knows the window, then clear the clipboard.
await sky.get_app_state({ app: "TextEdit" });
execFileSync("/usr/bin/pbcopy", { input: "clipboard-sentinel" });

// The actual experiment: menu equivalents into a background app.
await sky.press_key({ app: "TextEdit", keys: "Cmd+a", background: true });
await sky.press_key({ app: "TextEdit", keys: "Cmd+c", background: true });

const clip = execFileSync("/usr/bin/pbpaste").toString();
const after = await frontmostName();
console.log("FRONTMOST-AFTER", after);
console.log("CLIPBOARD", JSON.stringify(clip.slice(0, 80)));
console.log("COPIED-IN-BACKGROUND", clip.includes(marker) ? "PASS" : "FAIL");
console.log("KEPT-FOCUS", after === before ? "PASS" : `FAIL (focus moved to ${after})`);

await sky.close();
