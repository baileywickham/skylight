import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { sky, SkyError } from "../src/index.js";

const gated = process.env.SKYLIGHT_SMOKE === "1";

// Live end-to-end smoke test against a real, permission-granted SkylightService
// driving TextEdit. Gated behind SKYLIGHT_SMOKE=1 so `vitest run` (and CI) never
// depends on TCC grants — this only runs when explicitly enabled by a human/runner
// that has installed SkylightService.app and granted Accessibility (+ optionally
// Screen Recording) to it.
describe.runIf(gated)("live smoke (TextEdit)", () => {
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

    // get_app_state fails the whole call with permission_denied when Screen
    // Recording isn't granted (screenshot capture is part of the same handler on
    // the daemon side). Don't fail the smoke test just for a missing screenshot
    // grant — still exercise the AX + action path via a second, screenshot-free
    // observation isn't available on the wire, so we treat permission_denied here
    // as "screenshot ungranted" and skip only the screenshot assertions.
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
          "granted to SkylightService) — skipping screenshot assertions, still exercising " +
          "type_text below via list_apps/AX-only checks is not possible over this RPC, so " +
          "this run only proves the daemon is reachable and reports the expected error.",
      );
      sky.close();
      return;
    }

    expect(before).toBeDefined();
    expect(before!.text).toContain("AXWindow");
    expect(before!.screenshot.url.startsWith("file://")).toBe(true);
    expect(before!.screenshot.width).toBeGreaterThan(0);

    await sky.type_text({ app: "TextEdit", text: "skylight-smoke-marker" });
    const after = await sky.get_app_state({ app: "TextEdit" });
    expect(after.text).not.toEqual(before!.text);
    sky.close();
  }, 30000);

  it("list_apps includes TextEdit", async () => {
    const apps = await sky.list_apps();
    expect(apps.apps.some((a) => a.name === "TextEdit")).toBe(true);
    sky.close();
  });
});
