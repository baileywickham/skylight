/**
 * Live verification that background ACTIONS against two apps overlap instead of
 * queueing behind one another.
 *
 * Uses `type_text` with an empty string: it posts no keystrokes (so nothing on
 * the machine is modified) but runs the whole action path — approval gate,
 * focus-without-raise, and the fixed post-action settle. That settle is the
 * measurable cost, so sequential should take about twice as long as parallel.
 */
import { sky } from "../src/index.js";

const apps = process.argv.slice(2);
if (apps.length !== 2) throw new Error("usage: live-parallel-check.mts <appA> <appB>");

const ROUNDS = 5;
const noopActions = async (app: string) => {
  for (let i = 0; i < ROUNDS; i++) {
    await sky.type_text({ app, text: "", background: true });
  }
};

const frontmost = async () =>
  (await sky.list_apps()).apps.find((a) => a.is_frontmost)?.name ?? "(none)";

const time = async (label: string, run: () => Promise<unknown>) => {
  const t0 = performance.now();
  await run();
  const ms = Math.round(performance.now() - t0);
  console.log(`${label} ${ms}ms`);
  return ms;
};

for (const app of apps) await sky.get_app_state({ app });
const before = await frontmost();
console.log("FRONTMOST-BEFORE", before);

const sequential = await time("SEQUENTIAL", async () => {
  for (const app of apps) await noopActions(app);
});
const parallel = await time("PARALLEL  ", () => Promise.all(apps.map(noopActions)));

// Same app twice must NOT overlap — that is the invariant protecting per-app
// state, and it should cost the same as running them sequentially.
const sameApp = await time("SAME-APP  ", () =>
  Promise.all([noopActions(apps[0]), noopActions(apps[0])]));

console.log("SPEEDUP", (sequential / parallel).toFixed(2) + "x");
console.log("DIFFERENT-APPS-OVERLAP", parallel < sequential * 0.7 ? "PASS" : "FAIL");
console.log("SAME-APP-SERIALIZED", sameApp > sequential * 0.85 ? "PASS" : "FAIL");
console.log("FRONTMOST-AFTER", await frontmost());

await sky.close();
