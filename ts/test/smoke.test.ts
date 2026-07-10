import { afterAll, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { sky, SkyError } from "../src/index.js";

const gated = process.env.SKYLIGHT_SMOKE === "1";
const MARKER = "skylight-smoke-marker";

/**
 * Runs a smoke body, skipping gracefully (like the first test does) when the
 * failure is an ungranted TCC permission rather than a real regression — e.g.
 * Screen Recording missing makes every get_app_state fail permission_denied.
 * Any other error still fails the test.
 */
async function skipOnPermissionDenied(what: string, body: () => Promise<void>): Promise<void> {
  try {
    await body();
  } catch (err) {
    if (err instanceof SkyError && err.code === "permission_denied") {
      console.warn(
        `skylight smoke: ${what} returned permission_denied (TCC grant not given to ` +
          "SkylightService) — skipping this check; grant Accessibility + Screen Recording to run it.",
      );
      return;
    }
    throw err;
  }
}

// Live end-to-end smoke test against a real, permission-granted SkylightService
// driving TextEdit. Gated behind SKYLIGHT_SMOKE=1 so `vitest run` (and CI) never
// depends on TCC grants — this only runs when explicitly enabled by a human/runner
// that has installed SkylightService.app and granted Accessibility (+ optionally
// Screen Recording) to it.
describe.runIf(gated)("live smoke (TextEdit)", () => {
  // Close the shared socket even if an assertion fails mid-test; the lazy
  // singleton reconnects on the next call, so a single close at the end is safe.
  afterAll(() => {
    sky.close();
  });

  it("get_app_state -> type_text changes the AX tree", async () => {
    // Requires: SkylightService installed + granted, TextEdit open with a document.
    // Plain `open -a TextEdit` is not enough: on a machine where "Ask to keep
    // changes when closing documents" is off (common default), TextEdit launches
    // straight into an Open panel instead of a blank document, which breaks the
    // AX/type_text assertions below. Force a fresh, unsaved scratch document via
    // AppleScript instead of relying on launch-time defaults, and never touch any
    // existing file.
    execFileSync("osascript", ["-e", 'tell application "TextEdit" to make new document']);
    await new Promise((r) => setTimeout(r, 1500));

    // The daemon's get_app_state couples the AX capture with the screenshot in a
    // single handler, so when Screen Recording is ungranted the whole call fails
    // with permission_denied and no AX-only capture is available over the wire —
    // all this test can do is treat permission_denied as "screenshot ungranted"
    // and skip the screenshot-dependent assertions gracefully.
    let before: Awaited<ReturnType<typeof sky.get_app_state>> | undefined;
    let screenshotsGated = false;
    try {
      before = await sky.get_app_state({ app: "TextEdit" });
    } catch (err) {
      if (err instanceof SkyError && err.code === "permission_denied") {
        screenshotsGated = true;
      } else {
        throw err;
      }
    }

    if (screenshotsGated) {
      console.warn(
        "skylight smoke: get_app_state returned permission_denied (Screen Recording not " +
          "granted to SkylightService) — an AX-only capture isn't available over this RPC, " +
          "so this run only proves the daemon is reachable and reports the expected error.",
      );
      return;
    }

    expect(before).toBeDefined();
    expect(before!.text).toContain("AXWindow");
    expect(before!.text).not.toContain(MARKER);
    expect(before!.screenshot).toBeTruthy();
    expect(before!.screenshot!.url.startsWith("file://")).toBe(true);
    expect(before!.screenshot!.width).toBeGreaterThan(0);

    await sky.type_text({ app: "TextEdit", text: MARKER });
    const after = await sky.get_app_state({ app: "TextEdit" });
    // The typed marker must actually land in the AX tree — a bare inequality
    // between before/after could false-pass on unrelated tree churn (element
    // renumbering, focus ring, autocorrect popover).
    expect(after.text).toContain(MARKER);
    expect(after.text).not.toEqual(before!.text);
  }, 30000);

  it("list_apps includes TextEdit", async () => {
    await skipOnPermissionDenied("list_apps", async () => {
      const apps = await sky.list_apps();
      expect(apps.apps.some((a) => a.name === "TextEdit")).toBe(true);
    });
  });

  it("select_text selects a substring in TextEdit", async () => {
    // get_app_state requires Screen Recording (the daemon couples capture +
    // screenshot), so an ungranted run must skip here exactly like the first
    // test does, not fail.
    await skipOnPermissionDenied("select_text smoke", async () => {
      const state = await sky.get_app_state({ app: "TextEdit" });
      const textArea = state.text.split("\n").find((l) => l.includes("AXTextArea"));
      expect(textArea).toBeDefined();
      const index = Number(textArea!.match(/^\s*\[(\d+)\]/)![1]);
      const r = await sky.select_text({ app: "TextEdit", element_index: index, text: "smoke", selection_type: "select" });
      expect(r.done).toBe(true);
    });
    sky.close();
  }, 30000);
});
